pragma solidity 0.5.17;

import "./CNative.sol";

/**
 * @title Protocol's Maximillion Contract
 * @author RBL
 */
contract Maximillion {
    /**
     * @notice The default cNative market to repay in
     */
    CNative public cNative;

    /**
     * @notice Construct a Maximillion to repay max in a CNative market
     */
    constructor(CNative cNative_) public {
        cNative = cNative_;
    }

    /**
     * @notice msg.sender sends native token to repay an account's borrow in the cNative market
     * @dev The provided native token is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     */
    function repayBehalf(address borrower) public payable {
        repayBehalfExplicit(borrower, cNative);
    }

    /**
     * @notice msg.sender sends native token to repay an account's borrow in a cNative market
     * @dev The provided native token is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     * @param cNative_ The address of the cNative contract to repay in
     */
    function repayBehalfExplicit(address borrower, CNative cNative_) public payable {
        uint received = msg.value;
        uint borrows = cNative_.borrowBalanceCurrent(borrower);
        if (received > borrows) {
            cNative_.repayBorrowBehalf.value(borrows)(borrower);
            msg.sender.transfer(received - borrows);
        } else {
            cNative_.repayBorrowBehalf.value(received)(borrower);
        }
    }
}
