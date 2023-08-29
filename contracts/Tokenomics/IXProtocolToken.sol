// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IXProtocolToken is IERC20Upgradeable {
  function convertTo(uint256 amount, address to) external;

  function isTransferWhitelisted(address account) external view returns (bool);
}