// https://arbiscan.io/address/0x3CAaE25Ee616f2C8E13C74dA0813402eae3F496b


// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./IProtocolToken.sol";
import "./IXProtocolToken.sol";
import "./rewards/IXProtocolRewards.sol";
import "./IAllowlist.sol";

/*
 * xProtocol storage
 */
contract XProtocolStorageV1 {

  struct XProtocolBalance {
    uint256 allocatedAmount; // Amount of xProtocol allocated to a Usage
    uint256 redeemingAmount; // Total amount of xProtocol currently being redeemed
  }

  struct RedeemInfo {
    uint256 protocolAmount; // Protocol amount to receive when vesting has ended
    uint256 xProtocolAmount; // xProtocol amount to redeem
    uint256 endTime;
    IXProtocolRewards rewardsAddress;
    uint256 rewardsAllocation; // Share of redeeming xProtocol to allocate to the Rewards Usage contract
  }

  IProtocolToken public protocolToken; // Protocol token to convert to/from
  IXProtocolRewards public rewardsAddress; // Rewards contract

  EnumerableSet.AddressSet internal _transferWhitelist; // addresses allowed to send/receive xProtocol
  IAllowList public kycVerifier; // KYC verifier contract  

  uint256 public constant MAX_FIXED_RATIO = 100; // 100%

  // Redeeming min/max settings
  uint256 public minRedeemRatio;
  uint256 public maxRedeemRatio;
  uint256 public minRedeemDuration;
  uint256 public maxRedeemDuration;
  // Adjusted rewards for redeeming xProtocol
  uint256 public redeemRewardsAdjustment;

  mapping(address => XProtocolBalance) public xProtocolBalances; // User's xProtocol balances
  mapping(address => RedeemInfo[]) public userRedeems; // User's redeeming instances

  /********************************************/
  /****************** EVENTS ******************/
  /********************************************/

  event Convert(address indexed from, address to, uint256 amount);
  event UpdateRedeemSettings(uint256 minRedeemRatio, uint256 maxRedeemRatio, uint256 minRedeemDuration, uint256 maxRedeemDuration, uint256 redeemRewardsAdjustment);
  event UpdateRewardsAddress(address previousRewardsAddress, address newRewardsAddress);
  event SetTransferWhitelist(address account, bool add);
  event Redeem(address indexed userAddress, uint256 xProtocolAmount, uint256 protocolAmount, uint256 duration);
  event FinalizeRedeem(address indexed userAddress, uint256 xProtocolAmount, uint256 protocolAmount);
  event CancelRedeem(address indexed userAddress, uint256 xProtocolAmount);
  event UpdateRedeemRewardsAddress(address indexed userAddress, uint256 redeemIndex, address previousRewardsAddress, address newRewardsAddress);
  event Allocate(address indexed userAddress, address indexed usageAddress, uint256 amount);
  event Deallocate(address indexed userAddress, address indexed usageAddress, uint256 amount, uint256 fee);
  event KYCVerifierChanged(address indexed previousVerifier, address indexed newVerifier);
}