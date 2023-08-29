// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import "@quadrata/contracts/interfaces/IQuadReader.sol";
import "@quadrata/contracts/interfaces/IQuadPassportStore.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./IAllowlist.sol";

/**
 * @title Quadrata gateway contract
 * @author RBL
 */
contract QuadrataGateway is IAllowList, AccessControl { 
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;
    
    /// Passport entry cache
    struct passportEntry{
        /// evaluated result
        bool value;
        /// Calculated expiration timestamp
        uint256 expiresIn;
    }
    /// Role that are authorized to call allowed
    bytes32 public constant QUADRATA_QUERIER_ROLE = keccak256("QUADRATA_QUERIER_ROLE"); 
    /// Role that are authorized to check the cache
    bytes32 public constant QUADRATA_CACHE_ROLE = keccak256("QUADRATA_CACHE_ROLE");
    /// Country bytes
    bytes32 public constant COUNTRY = keccak256("COUNTRY");
    /// Quadrata passport reader contract interface
    IQuadReader immutable public quadrataReader;    
    /// Users passport attribute cache
    mapping (address => passportEntry) internal _passportCache;
    /// Users passport cache keys
    EnumerableSet.AddressSet internal _passportCacheKeys;
    /// Passport attribute cache expiration time
    uint public passportCacheExpirationTime;
    /// Blocklisted countries
    EnumerableSet.Bytes32Set internal _blocklistedCountries;
    /// Emitted when a new cache expiration time is set
    event NewPassportCacheExpirationTime(uint oldCacheExpirationTime, uint newCacheExpirationTime);
    /// Emitted when a country is addded to blocklist
    event CountryAddedToBlocklist(bytes32 country);
    /// Emitted when a country is removed from blocklist
    event CountryRemovedFromBlocklist(bytes32 country);
    /// Emitted when passport cache is wiped
    event PassportCacheWiped();
    
    constructor(IQuadReader quadrataReader_, uint passportCacheExpirationTime_) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);        
        quadrataReader = quadrataReader_;        
        passportCacheExpirationTime = passportCacheExpirationTime_;
    }

    /**
     * @notice Add countries to blocklist
    */
    function addCountriesToBlocklist(bytes32[] calldata countries_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 length = countries_.length;
        require(length > 0, "addCountriesToBlocklist: invalid length");

        uint256 index;        
        for ( ; index < length; ) {
            bytes32 country = countries_[index];            
            _blocklistedCountries.add(country); 
            emit CountryAddedToBlocklist(country);          
            unchecked { ++index; }
        }
    }

    /**
     * @notice Remove countries from blocklist
    */
    function removeCountriesFromBlocklist(bytes32[] calldata countries_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 length = countries_.length;
        require(length > 0, "removeCountriesFromBlocklist: invalid length");

        uint256 index;        
        for ( ; index < length; ) {   
            bytes32 country = countries_[index];         
            _blocklistedCountries.remove(country);     
            emit CountryRemovedFromBlocklist(country);
            unchecked { ++index; }
        }
    }

    /**
     * @notice Get the passport cache length
    */
    function getCacheLength() view external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256){
        return _passportCacheKeys.length();
    }

    /**
     * @notice Clear the passport cache for number of addresses requested
    */
    function clearAllCache(uint256 numberOfEntriesToRemove) external onlyRole(DEFAULT_ADMIN_ROLE){ 
        uint256 length = _passportCacheKeys.length();       

        require(length > 0, "clearAllCache: invalid cache length");
        require(numberOfEntriesToRemove > 0 && numberOfEntriesToRemove <= length, "clearAllCache: invalid nunberOfEntriesToRemove");        
        
        uint256 index = length - 1;
        uint256 indexEnd = length - numberOfEntriesToRemove;
        
        while (index >= indexEnd) {           
            address address_ = _passportCacheKeys.at(index);            
            delete _passportCache[address_];          
            _passportCacheKeys.remove(address_);

            if(index == 0){
                break;
            }

            unchecked { --index; }
        }
        
        emit PassportCacheWiped();
    }

    /**
     * @notice Clear the passport cache for especific addresses
     */
    function clearCache(address[] calldata addresses_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 length = addresses_.length;
        require(length > 0, "clearCache: invalid addresses_ length");

        uint256 index;        
        for ( ; index < length; ) {
            address address_ = addresses_[index];            
            delete _passportCache[address_];
            _passportCacheKeys.remove(address_);          
            unchecked { ++index; }
        }        
    }

    /**
     * @notice Update the passport cache expiration time.
     * This function doesn't update the cache itself, the new expiration time will
     * be used for next cached values
    */
    function updatePassportCacheExpirationTime(uint passportCacheExpirationTime_) external onlyRole(DEFAULT_ADMIN_ROLE){
        emit NewPassportCacheExpirationTime(passportCacheExpirationTime, passportCacheExpirationTime_);
        passportCacheExpirationTime = passportCacheExpirationTime_;
    }

    /**
     * @notice Get cached value of an address
     */
    function getCache(address address_) public view onlyRole(QUADRATA_CACHE_ROLE) returns (passportEntry memory) {
        return _passportCache[address_];
    }

    /**
     * @notice Check if an address is allowed
     */
    function allowed(address address_) public onlyRole(QUADRATA_QUERIER_ROLE) returns (bool) { 
        require(_blocklistedCountries.length() > 0, "allowed: invalid blocklisted countries length");
        passportEntry storage attribute = _passportCache[address_];        
        
        if(attribute.expiresIn < block.timestamp) {
            IQuadPassportStore.Attribute[] memory attributes = quadrataReader.getAttributes(
            address_, 
            COUNTRY);
                        
            uint256 length = attributes.length;
            uint256 index = 1;
            if(length > 0){
                // users with country info, we should update the cache
                bool result = !_blocklistedCountries.contains(attributes[0].value);
                for ( ; index < length; ) {                    
                    // only users residing outside the blocklisted countries are allowed       
                    result = result && !_blocklistedCountries.contains(attributes[index].value);
                    unchecked { ++index; }
                }
                
                attribute.value = result;
                attribute.expiresIn = block.timestamp + passportCacheExpirationTime;   
                _passportCacheKeys.add(address_);
            }else{
                // users without country info are not allowed
                return false;
            }
        }
        return attribute.value;
    }
}
