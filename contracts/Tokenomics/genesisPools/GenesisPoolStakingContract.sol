pragma solidity 0.5.17;

import "../../OpenZeppelin/ReentrancyGuard.sol";
import "./GenesisPoolStakingContractStorage.sol";
import "./GenesisPoolStakingContractProxy.sol";
import "../../EIP20Interface.sol";
import "../../SafeMath.sol";

contract GenesisPoolStakingContract is ReentrancyGuard, GenesisPoolStakingContractStorage {
    using SafeMath for uint256;

    constructor() public {
        admin = msg.sender;
    }

    /********************************************************
     *                                                      *
     *                   PUBLIC FUNCTIONS                   *
     *                                                      *
     ********************************************************/

    /**
     * Deposit Market's CTokens into the staking Genesis Pool.
     *
     * @param cTokenAmount The amount of CToken tokens to deposit
     */
    function deposit(uint cTokenAmount) external nonReentrant {
        require(genesisPoolCTokenAddress != address(0), "GenesisPool CToken address can not be zero");
        require(block.timestamp >= depositStartTimestamp && depositStartTimestamp > 0, "GenesisPool deposits not enabled yet");
        require(block.timestamp <= depositEndTimestamp && depositEndTimestamp > 0, "GenesisPool deposit period closed");

        EIP20Interface genesisPoolToken = EIP20Interface(genesisPoolCTokenAddress);
        uint contractBalance = genesisPoolToken.balanceOf(address(this));
        genesisPoolToken.transferFrom(msg.sender, address(this), cTokenAmount);
        uint depositedAmount = genesisPoolToken.balanceOf(address(this)).sub(contractBalance);

        require(depositedAmount > 0, "Zero deposit");

        distributeReward(msg.sender);

        totalSupplies = totalSupplies.add(depositedAmount);
        supplyAmount[msg.sender] = supplyAmount[msg.sender].add(depositedAmount);
    }

    /**
     * Redeem deposited CToken tokens from the contract.
     *
     * @param cTokenAmount Redeem amount
     */
    function redeem(uint cTokenAmount) external nonReentrant {
        require(genesisPoolCTokenAddress != address(0), "GenesisPool CToken address can not be zero");
        require(cTokenAmount <= supplyAmount[msg.sender], "Too large withdrawal");

        distributeReward(msg.sender);

        supplyAmount[msg.sender] = supplyAmount[msg.sender].sub(cTokenAmount);
        totalSupplies = totalSupplies.sub(cTokenAmount);

        EIP20Interface genesisPoolToken = EIP20Interface(genesisPoolCTokenAddress);
        genesisPoolToken.transfer(msg.sender, cTokenAmount);
    }

    /**
     * Claim pending rewards from the staking contract by transferring them
     * to the requester.
     */
    function claimRewards() external nonReentrant {
        distributeReward(msg.sender);

        uint amount = accruedReward[msg.sender];
        address recipient = msg.sender;

        require(accruedReward[recipient] <= amount, "Not enough accrued rewards");
        require(rewardTokenAddress != address(0), "reward token address can not be zero");

        EIP20Interface token = EIP20Interface(rewardTokenAddress);
        accruedReward[recipient] = accruedReward[recipient].sub(amount);
        token.transfer(recipient, amount);
    }

    /**
     * Get the current amount of available rewards for claiming.
     *
     * @return Balance of claimable reward tokens
     */
    function getClaimableRewards() external view returns(uint) {
        uint rewardIndexDelta = rewardIndex.sub(supplierRewardIndex[msg.sender]);
        uint claimableReward = rewardIndexDelta.mul(supplyAmount[msg.sender]).div(1e36).add(accruedReward[msg.sender]);

        return claimableReward;
    }

    /********************************************************
     *                                                      *
     *               ADMIN-ONLY FUNCTIONS                   *
     *                                                      *
     ********************************************************/

    /**
     * Set reward distribution speed.
     *
     * @param speed New reward speed
     */
    function setRewardSpeed(uint speed) external adminOnly {
        if (accrualBlockTimestamp != 0) {
            accrueReward();
        }

        rewardSpeed = speed;
    }

    /**
     * Set ERC20 reward token contract address.
     *
     * @param newRewardTokenAddress New contract address
     */
    function setRewardTokenAddress(address newRewardTokenAddress) external adminOnly {
        require(rewardTokenAddress == address(0), 'invalid reward token address');
        require(genesisPoolCTokenAddress  != address(0), 'pool token address must be set');
        require(newRewardTokenAddress != genesisPoolCTokenAddress, "Cannot set pool token address");
        rewardTokenAddress = newRewardTokenAddress;
    }

    /**
     * Set Market's CToken contract address for this genesis pool
     *
     * @param newGenesisPoolCTokenAddress CToken contract address for this genesis pool
     */
    function setGenesisPoolCTokenAddress(address newGenesisPoolCTokenAddress) external adminOnly {
        require(genesisPoolCTokenAddress == address(0), 'genesis pool token already defined');

        genesisPoolCTokenAddress = newGenesisPoolCTokenAddress;
    }

    /**
     * Accept this contract as the implementation for a proxy.
     *
     * @param proxy GenesisPoolStakingContractProxy
     */
    function becomeImplementation(GenesisPoolStakingContractProxy proxy) external {
        require(msg.sender == proxy.admin(), "Only proxy admin can change the implementation");
        proxy.acceptPendingImplementation();
    }

    /********************************************************
     *                                                      *
     *                  INTERNAL FUNCTIONS                  *
     *                                                      *
     ********************************************************/

    /**
     * Update reward accrual state.
     *
     * @dev accrueReward() must be called every time the token balances
     *      or reward speeds change
     */
    function accrueReward() internal {
        uint blockTimestampDelta = block.timestamp.sub(accrualBlockTimestamp);
        accrualBlockTimestamp = block.timestamp;

        if (blockTimestampDelta == 0 || totalSupplies == 0 || rewardSpeed == 0) {
            return;
        }

        uint accrued = rewardSpeed.mul(blockTimestampDelta);
        uint accruedPerCToken = accrued.mul(1e36).div(totalSupplies);

        rewardIndex = rewardIndex.add(accruedPerCToken);
    }

    /**
     * Calculate accrued rewards for a single account based on the reward indexes.
     *
     * @param recipient Account for which to calculate accrued rewards
     */
    function distributeReward(address recipient) internal {
        accrueReward();

        uint rewardIndexDelta = rewardIndex.sub(supplierRewardIndex[recipient]);
        uint accruedAmount = rewardIndexDelta.mul(supplyAmount[recipient]).div(1e36);
        accruedReward[recipient] = accruedReward[recipient].add(accruedAmount);
        supplierRewardIndex[recipient] = rewardIndex;
    }

    /// Updates the GenesisPool deposit period
    /// @param depositStartTimestamp_ Deposits period start timestamp
    /// @param depositEndTimestamp_  Deposits period end timestamp, after that, 
    /// deposits are closed and starts the countdown which it will become withdrawal-only
    function setDepositPeriod(uint depositStartTimestamp_, uint depositEndTimestamp_) external adminOnly {
        require(depositStartTimestamp_ > 0, 'invalid depositStartTimestamp_');
        require(depositEndTimestamp_ > depositStartTimestamp_, 'invalid depositEndTimestamp_');        

        depositStartTimestamp = depositStartTimestamp_;
        depositEndTimestamp = depositEndTimestamp_;
    }

    /**
    * @dev Emergency withdraw token's balance on the contract
    * @dev Can't withdrawal user's deposits
    */
    function emergencyWithdraw(EIP20Interface token) public nonReentrant adminOnly {
        require(address(token) != genesisPoolCTokenAddress, "Can't withdrawal user's deposits");
        uint256 balance = token.balanceOf(address(this));
        uint256 genesisPoolBefore = EIP20Interface(genesisPoolCTokenAddress).balanceOf(address(this));
        require(balance > 0, "emergencyWithdraw: token balance is null");
        token.transfer(msg.sender, balance);
        uint256 genesisPoolBalance =  EIP20Interface(genesisPoolCTokenAddress).balanceOf(address(this)).sub(genesisPoolBefore);        
        require(genesisPoolBalance == 0, "genesis pool token should not be withdraw");
    }

    /********************************************************
     *                                                      *
     *                      MODIFIERS                       *
     *                                                      *
     ********************************************************/

    modifier adminOnly {
        require(msg.sender == admin, "admin only");
        _;
    }
}
