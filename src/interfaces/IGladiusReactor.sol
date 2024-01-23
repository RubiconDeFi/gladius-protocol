// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {SignedOrder} from "../base/ReactorStructs.sol";

/// @notice Interface for 'GladiusReactor'.
interface IGladiusReactor {
    /// @notice Execute part of a single order, specified in 'quantity'.
    /// @param order The order definition and valid signature to execute.
    /// @param quantity An amount, in the form of input token, to take from the order.
    function execute(
        SignedOrder calldata order,
        uint256 quantity
    ) external payable;

    /// @notice Execute part of a single order using the given callback data.
    /// @param order The order definition and valid signature to execute.
    /// @param quantity An amount, in the form of input token, to take from the order.
    /// @param callbackData The 'callbackData' to pass to the callback.
    function executeWithCallback(
        SignedOrder calldata order,
        uint256 quantity,
        bytes calldata callbackData
    ) external payable;

    /// @notice Execute parts of the given orders at once.
    /// @param orders The order definitions and valid signatures to execute.
    /// @param quantities Amounts, in the form of input tokens, to take from orders.
    function executeBatch(
        SignedOrder[] calldata orders,
        uint256[] calldata quantities
    ) external payable;

    /// @notice Execute parts of the given orders at once using a callback with the given callback data.
    /// @param orders The order definitions and valid signatures to execute.
    /// @param quantities Amounts, in the form of input tokens, to take from orders.
    /// @param callbackData The 'callbackData' to pass to the callback.
    function executeBatchWithCallback(
        SignedOrder[] calldata orders,
        uint256[] calldata quantities,
        bytes calldata callbackData
    ) external payable;
}
