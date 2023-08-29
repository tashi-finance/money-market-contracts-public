pragma solidity 0.5.17;
pragma experimental ABIEncoderV2;

contract PythStructs {
    struct Price {
        // Price
        int64 price;
        // Confidence interval around the price
        uint64 conf;
        // Price exponent
        int32 expo;
        // Unix timestamp describing when the price was published
        uint publishTime;
    }

    struct TokenConfig {        
        address asset;
        bytes32 pythId;        
        uint64 maxStalePeriod;
    }   
}

/// @title Consume prices from the Pyth Network (https://pyth.network/).
interface IPyth {
    /// @notice Returns the price that is no older than `age` seconds of the current time.
    /// @dev This function is a sanity-checked version of `getPriceUnsafe` which is useful in
    /// applications that require a sufficiently-recent price. Reverts if the price wasn't updated sufficiently
    /// recently.
    /// @return price - please read the documentation of PythStructs.Price to understand how to use this safely.
    function getPriceNoOlderThan(
        bytes32 id,
        uint age
    ) external view returns (PythStructs.Price memory price);
}
