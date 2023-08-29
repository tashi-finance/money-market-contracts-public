// https://arbiscan.io/address/0x3CAaE25Ee616f2C8E13C74dA0813402eae3F496b


// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./IProtocolToken.sol";
import "./IXProtocolToken.sol";
import "./rewards/IXProtocolRewards.sol";
import "./XProtocolTokenStorage.sol";

/*
 * xProtocol is PROTOCOL's escrowed token obtainable by converting Protocol or esProtocol to it
 * It's non-transferable, except from/to whitelisted addresses
 * Only KYC addresses can mint it
 * It can be converted back to Protocol through a vesting process
 * This contract automatically allocates and deallocates user balances to the XProtocolRewards contract
 */
contract XProtocolToken is Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, ERC20Upgradeable, IXProtocolToken, XProtocolStorageV1 {
  using Address for address;
  using EnumerableSet for EnumerableSet.AddressSet;
  using SafeERC20 for IProtocolToken;
  
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(IProtocolToken protocolToken_, string memory name_, string memory symbol_) public initializer {  
    protocolToken = protocolToken_;
    _transferWhitelist.add(address(this));

    minRedeemRatio = 50; // 1:0.5
    maxRedeemRatio = 100; // 1:1
    minRedeemDuration = 15 days; // 1296000s
    maxRedeemDuration = 180 days; // 15552000s
    redeemRewardsAdjustment = 25; // 25%

    __ERC20_init(name_, symbol_);
    __ReentrancyGuard_init();
    __Ownable_init();
  }

  /***********************************************/
  /****************** MODIFIERS ******************/
  /***********************************************/

  /*
   * @dev Check if a redeem entry exists
   */
  modifier validateRedeem(address userAddress, uint256 redeemIndex) {
    require(redeemIndex < userRedeems[userAddress].length, "validateRedeem: redeem entry does not exist");
    _;
  }

  /**************************************************/
  /****************** PUBLIC VIEWS ******************/
  /**************************************************/

  /*
   * @dev Returns user's xProtocol balances
   */
  function getXProtocolBalance(address userAddress) external view returns (uint256 allocatedAmount, uint256 redeemingAmount) {
    XProtocolBalance storage balance = xProtocolBalances[userAddress];
    return (balance.allocatedAmount, balance.redeemingAmount);
  }

  /*
   * @dev returns redeemable Protocol for "amount" of xProtocol vested for "duration" seconds
   */
  function getProtocolByVestingDuration(uint256 amount, uint256 duration) public view returns (uint256) {
    if(duration < minRedeemDuration) {
      return 0;
    }

    // capped to maxRedeemDuration
    if (duration > maxRedeemDuration) {
      return amount * maxRedeemRatio / 100;
    }

    uint256 ratio = minRedeemRatio + (
      (duration - minRedeemDuration) * (maxRedeemRatio - minRedeemRatio)
      /(maxRedeemDuration - minRedeemDuration)
    );

    require(ratio <= maxRedeemRatio, "Ratio calculation overflow");

    return amount * ratio / 100;
  }

  /**
   * @dev returns quantity of "userAddress" pending redeems
   */
  function getUserRedeemsLength(address userAddress) external view returns (uint256) {
    return userRedeems[userAddress].length;
  }

  /**
   * @dev returns "userAddress" info for a pending redeem identified by "redeemIndex"
   */
  function getUserRedeem(address userAddress, uint256 redeemIndex) external view validateRedeem(userAddress, redeemIndex) returns (uint256 protocolAmount, uint256 xProtocolAmount, uint256 endTime, address xProtocolRewardsContract, uint256 rewardsAllocation) {
    RedeemInfo storage _redeem = userRedeems[userAddress][redeemIndex];
    return (_redeem.protocolAmount, _redeem.xProtocolAmount, _redeem.endTime, address(_redeem.rewardsAddress), _redeem.rewardsAllocation);
  }

  /**
   * @dev returns length of transferWhitelist array
   */
  function transferWhitelistLength() external view returns (uint256) {
    return _transferWhitelist.length();
  }

  /**
   * @dev returns transferWhitelist array item's address for "index"
   */
  function transferWhitelist(uint256 index) external view returns (address) {
    return _transferWhitelist.at(index);
  }

  /**
   * @dev returns if "account" is allowed to send/receive xProtocol
   */
  function isTransferWhitelisted(address account) external override view returns (bool) {
    return _transferWhitelist.contains(account);
  }

  /*******************************************************/
  /****************** OWNABLE FUNCTIONS ******************/
  /*******************************************************/

  /**
   * @dev Updates all redeem ratios and durations
   *
   * Must only be called by owner
   */
  function updateRedeemSettings(uint256 minRedeemRatio_, uint256 maxRedeemRatio_, uint256 minRedeemDuration_, uint256 maxRedeemDuration_, uint256 redeemRewardsAdjustment_) external onlyOwner {
    require(minRedeemRatio_ <= maxRedeemRatio_, "updateRedeemSettings: wrong ratio values");
    require(minRedeemDuration_ < maxRedeemDuration_, "updateRedeemSettings: wrong duration values");
    // should never exceed 100%
    require(maxRedeemRatio_ <= MAX_FIXED_RATIO && redeemRewardsAdjustment_ <= MAX_FIXED_RATIO, "updateRedeemSettings: wrong ratio values");

    minRedeemRatio = minRedeemRatio_;
    maxRedeemRatio = maxRedeemRatio_;
    minRedeemDuration = minRedeemDuration_;
    maxRedeemDuration = maxRedeemDuration_;
    redeemRewardsAdjustment = redeemRewardsAdjustment_;

    emit UpdateRedeemSettings(minRedeemRatio_, maxRedeemRatio_, minRedeemDuration_, maxRedeemDuration_, redeemRewardsAdjustment_);
  }

  /**
   * @dev Updates XProtocolRewards contract address
   *
   * Must only be called by owner
   */
  function updateRewardsAddress(IXProtocolRewards xProtocolContractAddress_) external onlyOwner {
    // if set to 0, also set divs earnings while redeeming to 0
    require(address(xProtocolContractAddress_) != address(0), "updateRewardsAddress: Invalid XProtocolRewards address");

    // Sanity check
    xProtocolContractAddress_.distributedTokensLength();

    emit UpdateRewardsAddress(address(rewardsAddress), address(xProtocolContractAddress_));
    rewardsAddress = xProtocolContractAddress_;
  }

  /**
   * @dev Adds or removes addresses from the transferWhitelist
   */
  function updateTransferWhitelist(address account, bool add) external onlyOwner {
    require(account != address(this), "updateTransferWhitelist: Cannot remove esProtocol from whitelist");

    if(add) _transferWhitelist.add(account);
    else _transferWhitelist.remove(account);

    emit SetTransferWhitelist(account, add);
  }

  /*****************************************************************/
  /******************  EXTERNAL PUBLIC FUNCTIONS  ******************/
  /*****************************************************************/

  /**
   * @dev Convert caller's "amount" of Protocol to xProtocol
   */
  function convert(uint256 amount) external nonReentrant {
    _convert(amount, msg.sender);
  }

  /**
   * @dev Convert caller's "amount" of Protocol to xProtocol to "to" address
   */
  function convertTo(uint256 amount, address to) external override nonReentrant {
    require(address(msg.sender).isContract(), "convertTo: not allowed");
    _convert(amount, to);
  }

  /**
   * @dev Initiates redeem process (xProtocol to Protocol)
   *
   * Handles rewards' compensation allocation during the vesting process if needed
   */
  function redeem(uint256 xProtocolAmount, uint256 duration) external nonReentrant {
    require(xProtocolAmount > 0, "redeem: xProtocolAmount cannot be null");
    require(duration >= minRedeemDuration, "redeem: duration too low");

    _transfer(msg.sender, address(this), xProtocolAmount);
    XProtocolBalance storage balance = xProtocolBalances[msg.sender];

    // get corresponding Protocol amount
    uint256 protocolAmount = getProtocolByVestingDuration(xProtocolAmount, duration);
    emit Redeem(msg.sender, xProtocolAmount, protocolAmount, duration);

    // Deallocate the total amount before allocating the adjusted amount while redeeming
    _deallocate(msg.sender, xProtocolAmount);

    // if redeeming is not immediate, go through vesting process
    if(duration > 0) {
      // add to SBT total
      balance.redeemingAmount = balance.redeemingAmount + xProtocolAmount;

      // handle rewards during the vesting process
      uint256 rewardsAllocation = xProtocolAmount * redeemRewardsAdjustment / 100;
      // only if compensation is active
      if(rewardsAllocation > 0) {
        // allocate to rewards
        rewardsAddress.allocate(msg.sender, rewardsAllocation, new bytes(0));
      }

      // add redeeming entry
      userRedeems[msg.sender].push(RedeemInfo(protocolAmount, xProtocolAmount, _currentBlockTimestamp() + duration, rewardsAddress, rewardsAllocation));
    } else {
      // immediately redeem for Protocol
      _finalizeRedeem(msg.sender, xProtocolAmount, protocolAmount);
    }
  }

  /**
   * @dev Finalizes redeem process when vesting duration has been reached
   *
   * Can only be called by the redeem entry owner
   */
  function finalizeRedeem(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
    XProtocolBalance storage balance = xProtocolBalances[msg.sender];
    RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];
    require(_currentBlockTimestamp() >= _redeem.endTime, "finalizeRedeem: vesting duration has not ended yet");

    // remove from SBT total
    balance.redeemingAmount = balance.redeemingAmount - _redeem.xProtocolAmount;
    _finalizeRedeem(msg.sender, _redeem.xProtocolAmount, _redeem.protocolAmount);

    // handle rewards compensation if any was active
    if(_redeem.rewardsAllocation > 0) {
      // deallocate from rewards
      _redeem.rewardsAddress.deallocate(msg.sender, _redeem.rewardsAllocation, new bytes(0));
    }

    // remove redeem entry
    _deleteRedeemEntry(redeemIndex);
  }

  /**
   * @dev Updates rewards address for an existing active redeeming process
   *
   * Can only be called by the involved user
   * Should only be used if rewards contract was to be migrated
   */
  function updateRedeemRewardsAddress(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
    RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];

    require(rewardsAddress != _redeem.rewardsAddress, "Invalid rewardAddress");
    require(address(rewardsAddress) != address(0), "Cannot unset redeem rewardAddress");

    // only if the active rewards contract is not the same anymore
    if(_redeem.rewardsAllocation > 0) {
      // deallocate from old rewards contract
      _redeem.rewardsAddress.deallocate(msg.sender, _redeem.rewardsAllocation, new bytes(0));
      // allocate to new used rewards contract
      rewardsAddress.allocate(msg.sender, _redeem.rewardsAllocation, new bytes(0));
    }

    emit UpdateRedeemRewardsAddress(msg.sender, redeemIndex, address(_redeem.rewardsAddress), address(rewardsAddress));
    _redeem.rewardsAddress = rewardsAddress;
  }

  /**
   * @dev Cancels an ongoing redeem entry
   *
   * Can only be called by its owner
   */
  function cancelRedeem(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
    XProtocolBalance storage balance = xProtocolBalances[msg.sender];
    RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];

    // make redeeming xProtocol available again
    balance.redeemingAmount = balance.redeemingAmount - _redeem.xProtocolAmount;
    _transfer(address(this), msg.sender, _redeem.xProtocolAmount);

    // handle rewards compensation if any was active
    if(_redeem.rewardsAllocation > 0) {
      // deallocate from rewards
      _redeem.rewardsAddress.deallocate(msg.sender, _redeem.rewardsAllocation, new bytes(0));
    }

    _allocate(msg.sender, _redeem.xProtocolAmount);

    emit CancelRedeem(msg.sender, _redeem.xProtocolAmount);

    // remove redeem entry
    _deleteRedeemEntry(redeemIndex);
  }

  /********************************************************/
  /****************** INTERNAL FUNCTIONS ******************/
  /********************************************************/

  /**
   * @dev Convert caller's "amount" of Protocol into xProtocol to "to"
   */
  function _convert(uint256 amount, address to) internal {
    require(amount != 0, "convert: amount cannot be null");

    // Validate KYC
    require(kycVerifier.allowed(to), "convert: KYC check needed");

    // mint new xProtocol
    _mint(to, amount);
    _allocate(to, amount);

    emit Convert(msg.sender, to, amount);
    protocolToken.safeTransferFrom(msg.sender, address(this), amount);
  }

  /**
   * @dev Finalizes the redeeming process for "userAddress" by transferring him "protocolAmount" and removing "xProtocolAmount" from supply
   *
   * Any vesting check should be ran before calling this
   * PROTOCOL excess is automatically burnt
   */
  function _finalizeRedeem(address userAddress, uint256 xProtocolAmount, uint256 protocolAmount) internal {
    uint256 protocolExcess = xProtocolAmount - protocolAmount;

    // sends due Protocol tokens
    protocolToken.safeTransfer(userAddress, protocolAmount);

    // burns PROTOCOL excess if any
    if (protocolExcess > 0) {
      protocolToken.safeTransfer(address(0x000000000000000000000000000000000000dEaD), protocolExcess);
    }
    _burn(address(this), xProtocolAmount);

    emit FinalizeRedeem(userAddress, xProtocolAmount, protocolAmount);
  }

  /**
   * @dev Allocates "userAddress" user's "amount" of available xProtocol to rewardsAddress contract
   *
   */
  function _allocate(address userAddress, uint256 amount) internal {
    require(amount > 0, "allocate: amount cannot be null");

    XProtocolBalance storage balance = xProtocolBalances[userAddress];

    // adjust user's xProtocol balances
    balance.allocatedAmount = balance.allocatedAmount + amount;

    rewardsAddress.allocate(userAddress, amount, new bytes(0));

    emit Allocate(userAddress, address(rewardsAddress), amount);
  }

  /**
   * @dev Deallocates "amount" of available xProtocol to rewardsAddress contract
   */
  function _deallocate(address userAddress, uint256 amount) internal {
    require(amount > 0, "deallocate: amount cannot be null");

    XProtocolBalance storage balance = xProtocolBalances[userAddress];
    // check if there is enough allocated xProtocol to deallocate
    require(balance.allocatedAmount >= amount, "deallocate: non authorized amount");

    // adjust user's xProtocol balances
    balance.allocatedAmount = balance.allocatedAmount - amount;

    rewardsAddress.deallocate(userAddress, amount, new bytes(0));

    emit Deallocate(userAddress, address(rewardsAddress), amount, 0);
  }

  function _deleteRedeemEntry(uint256 index) internal {
    userRedeems[msg.sender][index] = userRedeems[msg.sender][userRedeems[msg.sender].length - 1];
    userRedeems[msg.sender].pop();
  }

  /**
   * @dev Hook override to forbid transfers except from whitelisted addresses and minting
   */
  function _beforeTokenTransfer(address from, address to, uint256 /*amount*/) internal view override {
    require(from == address(0) || _transferWhitelist.contains(from) || _transferWhitelist.contains(to), "transfer: not allowed");
  }

  /**
   * @dev Utility function to get the current block timestamp
   */
  function _currentBlockTimestamp() internal view virtual returns (uint256) {
    /* solhint-disable not-rely-on-time */
    return block.timestamp;
  }

  /**
     * @notice Set the liquidators whitelist verifier contract
     */
    function updateKYCVerifier(IAllowList kycVerifier_) external onlyOwner {        
      emit KYCVerifierChanged(address(kycVerifier), address(kycVerifier_));
        kycVerifier = kycVerifier_;        
    }
}