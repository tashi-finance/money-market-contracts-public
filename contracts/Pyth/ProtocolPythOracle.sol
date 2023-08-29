pragma solidity 0.5.17;
pragma experimental ABIEncoderV2;

import "../OverridablePriceOracle.sol";
import "../CErc20.sol";
import "../EIP20Interface.sol";
import "../SafeMath.sol";
import "./PythInterface.sol";

contract ProtocolPythOracle is OverridablePriceOracle {
    using SafeMath for uint;

    IPyth public underlyingPythOracle;    

    /// @notice Underlying token configs by token symbol
    mapping(string => PythStructs.TokenConfig) public tokenConfigs;

    /// @notice Emit when setting a new pyth oracle address
    event PythOracleSet(address indexed newPythOracle);

    /// @notice Emit when a token config is added
    event TokenConfigAdded(
        address indexed asset,
        bytes32 indexed pythId,
        uint64 maxStalePeriod
    );

    constructor(string memory cNativeSymbol_) OverridablePriceOracle(cNativeSymbol_) public { }
    
    function _getPrice(address tokenAddress) internal view returns (uint) {
        EIP20Interface token = EIP20Interface(tokenAddress);
        return getPythPrice(getFeed(token.symbol()));
    }

    function _getEtherPrice() internal view returns (uint) {
        return getPythPrice(tokenConfigs[cNativeSymbol]);
    }

    /**
     * @notice Set single token config. `maxStalePeriod` cannot be 0 and `cToken` can't be a null address
     */
    function setTokenConfig(PythStructs.TokenConfig memory config) public onlyOwner {
        if (config.asset == address(0))
            revert("can't be zero address");

        if (config.maxStalePeriod == 0)
            revert("max stale period cannot be 0");

        if(config.pythId == 0)
            revert("Pyth Id cannot be 0");

        EIP20Interface token = EIP20Interface(config.asset);

        tokenConfigs[token.symbol()] = config;        

        emit TokenConfigAdded(            
            config.asset,
            config.pythId,
            config.maxStalePeriod
        );
    }

    /**
     * @notice Set single token config. `maxStalePeriod` cannot be 0 and `cToken` can't be a null address
     */
    function setNativeTokenConfig(PythStructs.TokenConfig memory config) public onlyOwner {
        if (config.maxStalePeriod == 0)
            revert("max stale period cannot be 0");

        if(config.pythId == 0)
            revert("Pyth Id cannot be 0");

        tokenConfigs[cNativeSymbol] = config;        

        emit TokenConfigAdded(            
            config.asset,
            config.pythId,
            config.maxStalePeriod
        );
    }

    /**
     * @notice Set the underlying Pyth oracle contract address     
     */
    function setUnderlyingPythOracle(IPyth underlyingPythOracle_) external onlyOwner {
        address pythAddress = address(underlyingPythOracle_);
        require(pythAddress != address(0) && pythAddress != address(this), "invalid Pyth oracle address");
        
        underlyingPythOracle = underlyingPythOracle_;
        emit PythOracleSet(pythAddress);
    }

    function getFeed(string memory tokenSymbol) internal view returns (PythStructs.TokenConfig memory config){         
        PythStructs.TokenConfig memory tokenConfig = tokenConfigs[tokenSymbol];
        
        if (tokenConfig.asset == address(0))
            revert("asset config doesn't exist");

        return tokenConfig;
    }

    function getPythPrice(PythStructs.TokenConfig memory tokenConfig) internal view returns (uint) {
        // if the price is expired after it's compared against `maxStalePeriod`, the following call will revert
        PythStructs.Price memory priceInfo = underlyingPythOracle.getPriceNoOlderThan(
            tokenConfig.pythId,
            tokenConfig.maxStalePeriod
        );

        require(priceInfo.price > 0, "invalid price");
        require(priceInfo.expo < 1, 'invalid exponential');
        uint price = uint(priceInfo.price);
        uint decimalDelta = uint(18).sub(uint(- priceInfo.expo));
                
        if (decimalDelta > 0) {
            return price.mul(10**uint(decimalDelta));            
        } else {
            return price;
        }
    }
}
