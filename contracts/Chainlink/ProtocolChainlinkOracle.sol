pragma solidity 0.5.17;

import "../OverridablePriceOracle.sol";
import "../CErc20.sol";
import "../EIP20Interface.sol";
import "../SafeMath.sol";
import "./AggregatorV2V3Interface.sol";

contract ProtocolChainlinkOracle is OverridablePriceOracle {
    using SafeMath for uint;

    mapping(bytes32 => AggregatorV2V3Interface) internal feeds;
    event FeedSet(address feed, string symbol);

    constructor(string memory cNativeSymbol_) OverridablePriceOracle(cNativeSymbol_) public { }
    
    function _getPrice(address tokenAddress) internal view returns (uint) {
        EIP20Interface token = EIP20Interface(tokenAddress);
        return getChainlinkPrice(getFeed(token.symbol()));
    }

    function _getEtherPrice() internal view returns (uint) {
        return getChainlinkPrice(getFeed(cNativeSymbol));
    }

    function getChainlinkPrice(AggregatorV2V3Interface feed) internal view returns (uint) {
        // Chainlink USD-denominated feeds store answers at 8 decimals
        uint decimalDelta = uint(18).sub(feed.decimals());
        // Ensure that we don't multiply the result by 0
        if (decimalDelta > 0) {
            return uint(feed.latestAnswer()).mul(10**decimalDelta);
        } else {
            return uint(feed.latestAnswer());
        }
    }

    function setFeed(string calldata symbol, address feed) external onlyOwner() {
        require(feed != address(0) && feed != address(this), "invalid feed address");
        emit FeedSet(feed, symbol);
        feeds[keccak256(abi.encodePacked(symbol))] = AggregatorV2V3Interface(feed);
    }

    function getFeed(string memory symbol) public view returns (AggregatorV2V3Interface) {
        return feeds[keccak256(abi.encodePacked(symbol))];
    }
}
