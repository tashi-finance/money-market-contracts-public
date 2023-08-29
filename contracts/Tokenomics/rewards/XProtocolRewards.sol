// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./IXProtocolRewards.sol";
import "../IXProtocolTokenUsage.sol";


/*
 * This contract is used to distribute rewards to users that allocated xProtocol here
 *
 * Rewards can be distributed in the form of one or more tokens
 * They are mainly managed to be received from the FeeManager contract, but other sources can be added (dev wallet for instance)
 *
 * The freshly received rewards are stored in a pending slot
 *
 * The content of this pending slot will be progressively transferred over time into a distribution slot
 * This distribution slot is the source of the rewards distribution to xProtocol allocators during the current cycle
 *
 * This transfer from the pending slot to the distribution slot is based on cycleRewardsPercent and CYCLE_PERIOD_SECONDS
 *
 */
contract XProtocolRewards is Ownable2Step, ReentrancyGuard, IXProtocolTokenUsage, IXProtocolRewards {
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  struct UserInfo {
    uint256 pendingRewards;
    uint256 rewardDebt;
  }

  struct RewardsInfo {
    uint256 currentDistributionAmount; // total amount to distribute during the current cycle
    uint256 currentCycleDistributedAmount; // amount already distributed for the current cycle (times 1e2)
    uint256 pendingAmount; // total amount in the pending slot, not distributed yet
    uint256 distributedAmount; // total amount that has been distributed since initialization
    uint256 accRewardsPerShare; // accumulated rewards per share (times 1e18)
    uint256 lastUpdateTime; // last time the rewards distribution occurred
    uint256 cycleRewardsPercent; // fixed part of the pending rewards to assign to currentDistributionAmount on every cycle
    bool distributionDisabled; // deactivate a token distribution (for temporary rewards)
  }

  // actively distributed tokens
  EnumerableSet.AddressSet private _distributedTokens;
  uint256 public constant MAX_DISTRIBUTED_TOKENS = 10;

  // rewards info for every rewards token
  mapping(address => RewardsInfo) public rewardsInfo;
  mapping(address => mapping(address => UserInfo)) public users;

  address public immutable xProtocolToken; // xProtocolToken contract

  mapping(address => uint256) public usersAllocation; // User's xProtocol allocation
  uint256 public totalAllocation; // Contract's total xProtocol allocation

  uint256 public constant MIN_CYCLE_REWARDS_PERCENT = 1; // 0.01%
  uint256 public constant DEFAULT_CYCLE_REWARDS_PERCENT = 100; // 1%
  uint256 public constant MAX_CYCLE_REWARDS_PERCENT = 10000; // 100%
  // rewards will be added to the currentDistributionAmount on each new cycle
  uint256 internal constant _cycleDurationSeconds = 7 days;
  uint256 public currentCycleStartTime;

  constructor(address xProtocolToken_, uint256 startTime_) {
    require(xProtocolToken_ != address(0), "zero address");
    xProtocolToken = xProtocolToken_;
    currentCycleStartTime = startTime_;
  }

  /********************************************/
  /****************** EVENTS ******************/
  /********************************************/

  event UserUpdated(address indexed user, uint256 previousBalance, uint256 newBalance);
  event RewardsCollected(address indexed user, address indexed token, uint256 amount);
  event CycleRewardsPercentUpdated(address indexed token, uint256 previousValue, uint256 newValue);
  event RewardsAddedToPending(address indexed token, uint256 amount);
  event DistributedTokenDisabled(address indexed token);
  event DistributedTokenRemoved(address indexed token);
  event DistributedTokenEnabled(address indexed token);

  /***********************************************/
  /****************** MODIFIERS ******************/
  /***********************************************/

  /**
   * @dev Checks if an index exists
   */
  modifier validateDistributedTokensIndex(uint256 index) {
    require(index < _distributedTokens.length(), "validateDistributedTokensIndex: index exists?");
    _;
  }

  /**
   * @dev Checks if token exists
   */
  modifier validateDistributedToken(address token) {
    require(_distributedTokens.contains(token), "validateDistributedTokens: token does not exists");
    _;
  }

  /**
   * @dev Checks if caller is the xProtocolToken contract
   */
  modifier xProtocolTokenOnly() {
    require(msg.sender == xProtocolToken, "xProtocolTokenOnly: caller should be xProtocolToken");
    _;
  }

  /*******************************************/
  /****************** VIEWS ******************/
  /*******************************************/

  function cycleDurationSeconds() external pure returns (uint256) {
    return _cycleDurationSeconds;
  }

  /**
   * @dev Returns the number of rewards tokens
   */
  function distributedTokensLength() external view override returns (uint256) {
    return _distributedTokens.length();
  }

  /**
   * @dev Returns rewards token address from given index
   */
  function distributedToken(uint256 index) external view override validateDistributedTokensIndex(index) returns (address){
    return address(_distributedTokens.at(index));
  }

  /**
   * @dev Returns true if given token is a rewards token
   */
  function isDistributedToken(address token) external view override returns (bool) {
    return _distributedTokens.contains(token);
  }

  /**
   * @dev Returns time at which the next cycle will start
   */
  function nextCycleStartTime() public view returns (uint256) {
    return currentCycleStartTime + _cycleDurationSeconds;
  }

  /**
   * @dev Returns user's rewards pending amount for a given token
   */
  function pendingRewardsAmount(address token, address userAddress) external view returns (uint256) {
    if (totalAllocation == 0) {
      return 0;
    }

    RewardsInfo storage rewardsInfo_ = rewardsInfo[token];

    uint256 accRewardsPerShare = rewardsInfo_.accRewardsPerShare;
    uint256 lastUpdateTime = rewardsInfo_.lastUpdateTime;
    uint256 rewardAmountPerSecond_ = _rewardsAmountPerSecond(token);

    // check if the current cycle has changed since last update
    if (_currentBlockTimestamp() > nextCycleStartTime()) {
      // get remaining rewards from last cycle
      accRewardsPerShare = accRewardsPerShare + (
        (nextCycleStartTime() - lastUpdateTime) * rewardAmountPerSecond_ * 1e16 / totalAllocation
      );
      lastUpdateTime = nextCycleStartTime();
      rewardAmountPerSecond_ = rewardsInfo_.pendingAmount * rewardsInfo_.cycleRewardsPercent / 100 
      / _cycleDurationSeconds;   
    }

    // get pending rewards from current cycle
    accRewardsPerShare = accRewardsPerShare + (
      (_currentBlockTimestamp() - lastUpdateTime) * rewardAmountPerSecond_ * 1e16 / totalAllocation
    );

    return (usersAllocation[userAddress] 
      * accRewardsPerShare 
      / 1e18)
      - users[token][userAddress].rewardDebt
      + users[token][userAddress].pendingRewards;
  }

  /**************************************************/
  /****************** PUBLIC FUNCTIONS **************/
  /**************************************************/

  /**
   * @dev Updates the current cycle start time if previous cycle has ended
   */
  function updateCurrentCycleStartTime() public {
    uint256 nextCycleStartTime_ = nextCycleStartTime();

    if (_currentBlockTimestamp() >= nextCycleStartTime_) {
      currentCycleStartTime = nextCycleStartTime_;
    }
  }

  /**
   * @dev Updates rewards info for a given token
   */
  function updateRewardsInfo(address token) external validateDistributedToken(token) {
    _updateRewardsInfo(token);
  }

  /****************************************************************/
  /****************** EXTERNAL PUBLIC FUNCTIONS  ******************/
  /****************************************************************/

  /**
   * @dev Updates all rewardsInfo
   */
  function massUpdateRewardsInfo() external {
    uint256 index;
    uint256 length = _distributedTokens.length();
    for ( ; index < length; ) {
      _updateRewardsInfo(_distributedTokens.at(index));
      unchecked { ++index; }
    }
  }

  /**
   * @dev Harvests caller's pending rewards of a given token
   */
  function harvestRewards(address token) external nonReentrant {
    if (!_distributedTokens.contains(token)) {
      require(rewardsInfo[token].distributedAmount > 0, "harvestRewards: invalid token");
    }

    _harvestRewards(token);
  }

  /**
   * @dev Harvests all caller's pending rewards
   */
  function harvestAllRewards() external nonReentrant {
    uint256 index;
    uint256 length = _distributedTokens.length();
    for ( ; index < length; ) {
      _harvestRewards(_distributedTokens.at(index));
      unchecked { ++index; }
    }
  }

  /**
   * @dev Transfers the given amount of token from caller to pendingAmount
   *
   * Must only be called by a trustable address
   */
  function addRewardsToPending(address token, uint256 amount) external override nonReentrant {
    uint256 prevTokenBalance = IERC20(token).balanceOf(address(this));
    RewardsInfo storage rewardsInfo_ = rewardsInfo[token];

    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

    // handle tokens with transfer tax
    uint256 receivedAmount = IERC20(token).balanceOf(address(this)) - prevTokenBalance;
    rewardsInfo_.pendingAmount = rewardsInfo_.pendingAmount + receivedAmount;

    emit RewardsAddedToPending(token, receivedAmount);
  }

  /**
   * @dev Emergency withdraw token's balance on the contract
   */
  function emergencyWithdraw(IERC20 token) public nonReentrant onlyOwner {
    uint256 balance = token.balanceOf(address(this));
    require(balance > 0, "emergencyWithdraw: token balance is null");
    _safeTokenTransfer(token, msg.sender, balance);
  }

  /**
   * @dev Emergency withdraw all reward tokens' balances on the contract
   */
  function emergencyWithdrawAll() external nonReentrant onlyOwner {
    uint256 index;
    uint256 length = _distributedTokens.length();
    for (; index < length; ) {
      emergencyWithdraw(IERC20(_distributedTokens.at(index)));
      unchecked{ ++index; }
    }
  }

  /*****************************************************************/
  /****************** OWNABLE FUNCTIONS  ******************/
  /*****************************************************************/

  /**
   * Allocates "userAddress" user's "amount" of xProtocol to this rewards contract
   *
   * Can only be called by xProtocolToken contract, which is trusted to verify amounts
   * "data" is only here for compatibility reasons (IxProtocolTokenUsage)
   */
  function allocate(address userAddress, uint256 amount, bytes calldata /*data*/) external override nonReentrant xProtocolTokenOnly {
    uint256 newUserAllocation = usersAllocation[userAddress] + amount;
    uint256 newTotalAllocation = totalAllocation + amount;
    _updateUser(userAddress, newUserAllocation, newTotalAllocation);
  }

  /**
   * Deallocates "userAddress" user's "amount" of xProtocol allocation from this rewards contract
   *
   * Can only be called by xProtocolToken contract, which is trusted to verify amounts
   * "data" is only here for compatibility reasons (IxProtocolTokenUsage)
   */
  function deallocate(address userAddress, uint256 amount, bytes calldata /*data*/) external override nonReentrant xProtocolTokenOnly {
    uint256 newUserAllocation = usersAllocation[userAddress] - amount;
    uint256 newTotalAllocation = totalAllocation - amount;
    _updateUser(userAddress, newUserAllocation, newTotalAllocation);
  }

  /**
   * @dev Enables a given token to be distributed as rewards
   *
   * Effective from the next cycle
   */
  function enableDistributedToken(address token) external onlyOwner {
    RewardsInfo storage rewardsInfo_ = rewardsInfo[token];
    require(
      rewardsInfo_.lastUpdateTime == 0 || rewardsInfo_.distributionDisabled,
      "enableDistributedToken: Already enabled rewards token"
    );
    require(_distributedTokens.length() < MAX_DISTRIBUTED_TOKENS, "enableDistributedToken: too many distributedTokens");
    // initialize lastUpdateTime if never set before
    if (rewardsInfo_.lastUpdateTime == 0) {
      rewardsInfo_.lastUpdateTime = _currentBlockTimestamp();
    }
    // initialize cycleRewardsPercent to the minimum if never set before
    if (rewardsInfo_.cycleRewardsPercent == 0) {
      rewardsInfo_.cycleRewardsPercent = DEFAULT_CYCLE_REWARDS_PERCENT;
    }
    rewardsInfo_.distributionDisabled = false;
    _distributedTokens.add(token);
    emit DistributedTokenEnabled(token);
  }

  /**
   * @dev Disables distribution of a given token as rewards
   *
   * Effective from the next cycle
   */
  function disableDistributedToken(address token) external onlyOwner {
    RewardsInfo storage rewardsInfo_ = rewardsInfo[token];
    require(
      rewardsInfo_.lastUpdateTime > 0 && !rewardsInfo_.distributionDisabled,
      "disableDistributedToken: Already disabled rewards token"
    );
    rewardsInfo_.distributionDisabled = true;
    emit DistributedTokenDisabled(token);
  }

  /**
   * @dev Updates the percentage of pending rewards that will be distributed during the next cycle
   *
   * Must be a value between MIN_CYCLE_REWARDS_PERCENT and MAX_CYCLE_REWARDS_PERCENT
   */
  function updateCycleRewardsPercent(address token, uint256 percent) external onlyOwner {
    require(percent <= MAX_CYCLE_REWARDS_PERCENT, "updateCycleRewardsPercent: percent mustn't exceed maximum");
    require(percent >= MIN_CYCLE_REWARDS_PERCENT, "updateCycleRewardsPercent: percent mustn't exceed minimum");
    RewardsInfo storage rewardsInfo_ = rewardsInfo[token];
    uint256 previousPercent = rewardsInfo_.cycleRewardsPercent;
    rewardsInfo_.cycleRewardsPercent = percent;
    emit CycleRewardsPercentUpdated(token, previousPercent, rewardsInfo_.cycleRewardsPercent);
  }

  /**
  * @dev remove an address from _distributedTokens
  *
  * Can only be valid for a disabled rewards token and if the distribution has ended
  */
  function removeTokenFromDistributedTokens(address tokenToRemove) external onlyOwner {
    RewardsInfo storage _rewardsInfo = rewardsInfo[tokenToRemove];
    require(_rewardsInfo.distributionDisabled && _rewardsInfo.currentDistributionAmount == 0, "removeTokenFromDistributedTokens: cannot be removed");
    _distributedTokens.remove(tokenToRemove);
    emit DistributedTokenRemoved(tokenToRemove);
  }

  /********************************************************/
  /****************** INTERNAL FUNCTIONS ******************/
  /********************************************************/

  /**
   * @dev Returns the amount of rewards token distributed every second (times 1e2)
   */
  function _rewardsAmountPerSecond(address token) internal view returns (uint256) {
    if (!_distributedTokens.contains(token)) return 0;
    return rewardsInfo[token].currentDistributionAmount * 1e2 / _cycleDurationSeconds;
  }

  /**
   * @dev Updates every user's rewards allocation for each distributed token
   */
  function _updateRewardsInfo(address token) internal {
    uint256 currentBlockTimestamp = _currentBlockTimestamp();
    RewardsInfo storage rewardsInfo_ = rewardsInfo[token];

    updateCurrentCycleStartTime();

    uint256 lastUpdateTime = rewardsInfo_.lastUpdateTime;
    uint256 accRewardsPerShare = rewardsInfo_.accRewardsPerShare;
    if (currentBlockTimestamp <= lastUpdateTime) {
      return;
    }

    // if no xProtocol is allocated or initial distribution has not started yet
    if (totalAllocation == 0 || currentBlockTimestamp < currentCycleStartTime) {
      rewardsInfo_.lastUpdateTime = currentBlockTimestamp;
      return;
    }

    uint256 currentDistributionAmount = rewardsInfo_.currentDistributionAmount; // gas saving
    uint256 currentCycleDistributedAmount = rewardsInfo_.currentCycleDistributedAmount; // gas saving

    // check if the current cycle has changed since last update
    if (lastUpdateTime < currentCycleStartTime) {
      // update accRewardsPerShare for the end of the previous cycle
      accRewardsPerShare = accRewardsPerShare + (
        ((currentDistributionAmount * 1e2) - currentCycleDistributedAmount)
          * 1e16
          / totalAllocation
      );

      // check if distribution is enabled
      if (!rewardsInfo_.distributionDisabled) {
        // transfer the token's cycleRewardsPercent part from the pending slot to the distribution slot
        rewardsInfo_.distributedAmount = rewardsInfo_.distributedAmount + currentDistributionAmount;

        uint256 pendingAmount = rewardsInfo_.pendingAmount;
        currentDistributionAmount = pendingAmount * rewardsInfo_.cycleRewardsPercent / 10000;
        rewardsInfo_.currentDistributionAmount = currentDistributionAmount;
        rewardsInfo_.pendingAmount = pendingAmount - currentDistributionAmount;
      } else {
        // stop the token's distribution on next cycle
        rewardsInfo_.distributedAmount = rewardsInfo_.distributedAmount + currentDistributionAmount;
        currentDistributionAmount = 0;
        rewardsInfo_.currentDistributionAmount = 0;
      }

      currentCycleDistributedAmount = 0;
      lastUpdateTime = currentCycleStartTime;
    }

    uint256 toDistribute = (currentBlockTimestamp - lastUpdateTime) * _rewardsAmountPerSecond(token);
    // ensure that we can't distribute more than currentDistributionAmount (for instance w/ a > 24h service interruption)
    if ((currentCycleDistributedAmount + toDistribute) > (currentDistributionAmount * 1e2 )) {
      toDistribute = (currentDistributionAmount * 1e2) - currentCycleDistributedAmount;
    }

    rewardsInfo_.currentCycleDistributedAmount = currentCycleDistributedAmount + toDistribute;
    rewardsInfo_.accRewardsPerShare = accRewardsPerShare + (toDistribute * 1e16 / totalAllocation);
    rewardsInfo_.lastUpdateTime = currentBlockTimestamp;
  }

  /**
   * Updates "userAddress" user's and total allocations for each distributed token
   */
  function _updateUser(address userAddress, uint256 newUserAllocation, uint256 newTotalAllocation) internal {
    uint256 previousUserAllocation = usersAllocation[userAddress];

    // for each distributedToken
    uint256 index;
    uint256 length = _distributedTokens.length();
    for ( ; index < length; ) {
      address token = _distributedTokens.at(index);
      _updateRewardsInfo(token);

      UserInfo storage user = users[token][userAddress];
      uint256 accRewardsPerShare = rewardsInfo[token].accRewardsPerShare;

      uint256 pending = (previousUserAllocation * accRewardsPerShare / 1e18) - user.rewardDebt;
      user.pendingRewards = user.pendingRewards + pending;
      user.rewardDebt = newUserAllocation * accRewardsPerShare / 1e18;
      unchecked { ++index; }
    }

    usersAllocation[userAddress] = newUserAllocation;
    totalAllocation = newTotalAllocation;

    emit UserUpdated(userAddress, previousUserAllocation, newUserAllocation);
  }

  /**
   * @dev Harvests msg.sender's pending rewards of a given token
   */
  function _harvestRewards(address token) internal {
    _updateRewardsInfo(token);

    UserInfo storage user = users[token][msg.sender];
    uint256 accRewardsPerShare = rewardsInfo[token].accRewardsPerShare;

    uint256 userXProtocolAllocation = usersAllocation[msg.sender];
    uint256 pending = user.pendingRewards + (
      (userXProtocolAllocation * accRewardsPerShare / 1e18) - user.rewardDebt
    );

    user.pendingRewards = 0;
    user.rewardDebt = userXProtocolAllocation * accRewardsPerShare / 1e18;

    _safeTokenTransfer(IERC20(token), msg.sender, pending);
    emit RewardsCollected(msg.sender, token, pending);
  }

  /**
   * @dev Safe token transfer function, in case rounding error causes pool to not have enough tokens
   */
  function _safeTokenTransfer(
    IERC20 token,
    address to,
    uint256 amount
  ) internal {
    if (amount > 0) {
      uint256 tokenBal = token.balanceOf(address(this));
      if (amount > tokenBal) {
        token.safeTransfer(to, tokenBal);
      } else {
        token.safeTransfer(to, amount);
      }
    }
  }

  /**
   * @dev Utility function to get the current block timestamp
   */
  function _currentBlockTimestamp() internal view virtual returns (uint256) {
    /* solhint-disable not-rely-on-time */
    return block.timestamp;
  }
}
