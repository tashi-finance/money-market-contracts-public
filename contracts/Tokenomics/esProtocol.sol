// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import "./esProtocolStorage.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import './IXProtocolToken.sol';

/*
 * esProtocol is Protocol's escrowed token obtainable by converting Protocol to it
 * It's non-transferable, except from/to whitelisted addresses
 * It can be converted back to Protocol through a vesting process 
 */
contract esProtocol is ERC20Upgradeable, ReentrancyGuardUpgradeable, Ownable2StepUpgradeable, esProtocolStorageV1 {
  using Address for address;
  using EnumerableSet for EnumerableSet.AddressSet;
  using SafeERC20 for IERC20;
  
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
      _disableInitializers();
  }

  function initialize(IERC20 protocolToken_, IXProtocolToken xProtocolToken_, string memory name_, string memory symbol_) public initializer {  
    protocolToken = protocolToken_;
    xProtocolToken = xProtocolToken_;
    _transferWhitelist.add(address(this));

    minRedeemRatio = 50; // 1:0.5
    maxRedeemRatio = 100; // 1:1
    minRedeemDuration = 15 days; // 1296000s
    maxRedeemDuration = 180 days; // 15552000s

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
   * @dev Returns user's esProtocol balances
   */
  function getESProtocolBalance(address userAddress) external view returns (uint256 redeemingAmount) {
    redeemingAmount = esProtocolBalances[userAddress];    
  }

  /*
   * @dev returns redeemable Protocol for "amount" of esProtocol vested for "duration" seconds
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
      / (maxRedeemDuration - minRedeemDuration)
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
  function getUserRedeem(address userAddress, uint256 redeemIndex) external view validateRedeem(userAddress, redeemIndex) returns (uint256 protocolAmount, uint256 esProtocolAmount, uint256 endTime) {
    RedeemInfo storage _redeem = userRedeems[userAddress][redeemIndex];
    return (_redeem.protocolAmount, _redeem.esProtocolAmount, _redeem.endTime);
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
   * @dev returns if "account" is allowed to send/receive esPrtocol
   */
  function isTransferWhitelisted(address account) external view returns (bool) {
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
  function updateRedeemSettings(uint256 minRedeemRatio_, uint256 maxRedeemRatio_, uint256 minRedeemDuration_, uint256 maxRedeemDuration_) external onlyOwner {
    require(minRedeemRatio_ <= maxRedeemRatio_, "updateRedeemSettings: wrong ratio values");
    require(minRedeemDuration_ < maxRedeemDuration_, "updateRedeemSettings: wrong duration values");
    // should never exceed 100%
    require(maxRedeemRatio_ <= MAX_FIXED_RATIO, "updateRedeemSettings: wrong ratio values");

    minRedeemRatio = minRedeemRatio_;
    maxRedeemRatio = maxRedeemRatio_;
    minRedeemDuration = minRedeemDuration_;
    maxRedeemDuration = maxRedeemDuration_;

    emit UpdateRedeemSettings(minRedeemRatio_, maxRedeemRatio_, minRedeemDuration_, maxRedeemDuration_);
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
   * @dev Convert caller's "amount" of Protocol to esProtocol
   */
  function convert(uint256 amount) external nonReentrant {
    _convert(amount, msg.sender);
  }

  /**
   * @dev Convert caller's "amount" of Protocol to esProtocol to "to" address
   */
  function convertTo(uint256 amount, address to) external nonReentrant {
    require(address(msg.sender).isContract(), "convertTo: not allowed");
    _convert(amount, to);
  }

  /**
   * @dev Convert caller's "amount" of esProtocol to xProtocol
   */
  function convertToXProtocol(uint256 amount) external nonReentrant{
    _convertToXProtocol(amount, msg.sender);
  }

  /**
   * @dev Convert caller's "amount" of esProtocol to xProtocol to "to" address
   */
  function convertToXProtocolTo(uint256 amount, address to) external nonReentrant{
    require(address(msg.sender).isContract(), "convertTo: not allowed");
    _convertToXProtocol(amount, to);   
  }

  /**
   * @dev Initiates redeem process (esProtocol to Protocol)
   *   
   */
  function redeem(uint256 esProtocolAmount, uint256 duration) external nonReentrant {
    require(esProtocolAmount > 0, "redeem: esProtocolAmount cannot be null");
    require(duration >= minRedeemDuration, "redeem: duration too low");

    _transfer(msg.sender, address(this), esProtocolAmount);
    uint256 balance = esProtocolBalances[msg.sender];

    // get corresponding Protocol amount
    uint256 protocolAmount = getProtocolByVestingDuration(esProtocolAmount, duration);
    emit Redeem(msg.sender, esProtocolAmount, protocolAmount, duration);

    // if redeeming is not immediate, go through vesting process
    if(duration > 0) {
      // add to SBT total
      balance = balance + esProtocolAmount;
      esProtocolBalances[msg.sender] = balance;
     
      // add redeeming entry
      userRedeems[msg.sender].push(RedeemInfo(protocolAmount, esProtocolAmount, _currentBlockTimestamp() + duration));
    } else {
      // immediately redeem for Protocol
      _finalizeRedeem(msg.sender, esProtocolAmount, protocolAmount);
    }
  }

  /**
   * @dev Finalizes redeem process when vesting duration has been reached
   *
   * Can only be called by the redeem entry owner
   */
  function finalizeRedeem(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
    uint256 redeemingAmount = esProtocolBalances[msg.sender];
    RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];
    require(_currentBlockTimestamp() >= _redeem.endTime, "finalizeRedeem: vesting duration has not ended yet");

    // remove from SBT total
    redeemingAmount = redeemingAmount - _redeem.esProtocolAmount;
    esProtocolBalances[msg.sender] = redeemingAmount;
    _finalizeRedeem(msg.sender, _redeem.esProtocolAmount, _redeem.protocolAmount);

    // remove redeem entry
    _deleteRedeemEntry(redeemIndex);
  }

  /**
   * @dev Cancels an ongoing redeem entry
   *
   * Can only be called by its owner
   */
  function cancelRedeem(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
    uint256 balance = esProtocolBalances[msg.sender];
    RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];

    // make redeeming esProtocol available again
    balance = balance - _redeem.esProtocolAmount;
    esProtocolBalances[msg.sender] = balance;
    _transfer(address(this), msg.sender, _redeem.esProtocolAmount);

    emit CancelRedeem(msg.sender, _redeem.esProtocolAmount);

    // remove redeem entry
    _deleteRedeemEntry(redeemIndex);
  }

  /********************************************************/
  /****************** INTERNAL FUNCTIONS ******************/
  /********************************************************/

  /**
   * @dev Convert caller's "amount" of PROTOCOL into esPROTOCOL to "to"
   */
  function _convert(uint256 amount, address to) internal {
    require(amount != 0, "convert: amount cannot be null");

    // mint new esPROTOCOL
    _mint(to, amount);

    emit Convert(msg.sender, to, amount);
    protocolToken.safeTransferFrom(msg.sender, address(this), amount);
  }

  /**
   * @dev Convert caller's "amount" of esPROTOCOL into xPROTOCOL to "to"
   */
  function _convertToXProtocol(uint256 amount, address to) internal{
    require(amount != 0, "convert: amount cannot be null");    
    require(IERC20Upgradeable(this).balanceOf(msg.sender) >= amount, "convert: insufficient balance");  
    // get back esProtocol tokens    
    _transfer(msg.sender, address(this), amount);
    // burn esProtocol tokens
    _burn(address(this), amount);

    // mint xProtocol tokens             
    protocolToken.approve(address(xProtocolToken), amount);
    xProtocolToken.convertTo(amount, to);    

    emit ConvertToXProtocol(msg.sender, to, amount);
  }

  /**
   * @dev Finalizes the redeeming process for "userAddress" by transferring him "protocolAmount" and removing "esProtocolAmount" from supply
   *
   * Any vesting check should be ran before calling this
   * PROTOCOL excess is automatically burnt
   */
  function _finalizeRedeem(address userAddress, uint256 esProtocolAmount, uint256 protocolAmount) internal {
    uint256 protocolExcess = esProtocolAmount - protocolAmount;

    // sends due PROTOCOL tokens
    protocolToken.safeTransfer(userAddress, protocolAmount);

    // burns PROTOCOL excess if any    
    if (protocolExcess > 0) {
      protocolToken.safeTransfer(address(0x000000000000000000000000000000000000dEaD), protocolExcess);
    }
    
    _burn(address(this), esProtocolAmount);

    emit FinalizeRedeem(userAddress, esProtocolAmount, protocolAmount);
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
}