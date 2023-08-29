pragma solidity 0.5.17;

import {CErc20Interface, CTokenInterface} from "./CTokenInterfaces.sol";
import "./SafeMath.sol";
import "./OpenZeppelin/ReentrancyGuard.sol";

/**
 * @title Protocol's CNative Helper Contract
 * @notice Redeem helper for CNative
 * @author RBL
 */
contract CNativeHelper is ReentrancyGuard {

    using SafeMath for uint;

    address public cNative;

    constructor(address _cNative) public {
        require(_cNative != address(0));

        cNative = _cNative;
    }

    function redeem(uint redeemTokens) public nonReentrant {
        bool transferFromSuccess = CTokenInterface(cNative).transferFrom(msg.sender, address(this), redeemTokens);
        require(transferFromSuccess, "cNative transferFrom failed");

        uint result = CErc20Interface(cNative).redeem(redeemTokens);
        require(result == 0, "cNative redeem failed"); // 0 = success, otherwise a failure

        (bool success, ) = msg.sender.call.value(address(this).balance)("");
        require(success, "Native token transfer failed");
    }

    function redeemUnderlying(uint redeemAmount) external {
        uint exchangeRate = CTokenInterface(cNative).exchangeRateCurrent();
        uint redeemTokens = redeemAmount.mul(1e18).div(exchangeRate);

        redeem(redeemTokens);
    }

    function() external payable {}
}
