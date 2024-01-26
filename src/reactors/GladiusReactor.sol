// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {SignedOrder, ResolvedOrder, InputToken, OutputToken} from "../base/ReactorStructs.sol";
import {DutchOutput, DutchInput} from "../lib/ExclusiveDutchOrderLib.sol";
import {ExclusivityOverrideLib} from "../lib/ExclusivityOverrideLib.sol";
import {PartialFillLib, GladiusOrder} from "../lib/PartialFillLib.sol";
import {BaseGladiusReactor} from "./BaseGladiusReactor.sol";
import {DutchDecayLib} from "../lib/DutchDecayLib.sol";
import {Permit2Lib} from "../lib/Permit2Lib.sol";

/// @notice Reactor for 'GladiusOrders' - exclusive Dutch orders.
///         The main differences between 'GladiusOrder' and 'ExclusiveDutchOrder' are:
///         * 'GladiusOrder' supports partial fills
///         * 'GladiusOrder' allows only 1 element in 'outputs' array.
///         * 'GladiusOrder' in/out amounts additionally resolved, based on
///           'quantity' argument, passed to 'execute' functions.
contract GladiusReactor is BaseGladiusReactor {
    using ExclusivityOverrideLib for ResolvedOrder;
    using PartialFillLib for GladiusOrder;
    using DutchDecayLib for DutchOutput[];
    using DutchDecayLib for DutchInput;
    using Permit2Lib for ResolvedOrder;
    using PartialFillLib for uint256;

    /// @notice Thrown when 'outputs' length != 1.
    error InvalidOutLength();
    /// @notice Thrown when an order's deadline is before its end time.
    error DeadlineBeforeEndTime();
    /// @notice Thrown when an order's end time is before its start time.
    error OrderEndTimeBeforeStartTime();
    /// @notice Thrown when an order's inputs and outputs both decay.
    error InputAndOutputDecay();

    /// @notice Resolves order into 'GladiusOrder' and applies a decay
    ///         function and a partition function on its in/out amounts.
    function resolve(
        SignedOrder calldata signedOrder,
        uint256 quantity
    ) internal view override returns (ResolvedOrder memory resolvedOrder) {
        GladiusOrder memory order = abi.decode(
            signedOrder.order,
            (GladiusOrder)
        );

        _validateOrder(order);

        /// @dev Apply decay function.
        InputToken memory input = order.input.decay(
            order.decayStartTime,
            order.decayEndTime
        );
        OutputToken[] memory outputs = order.outputs.decay(
            order.decayStartTime,
            order.decayEndTime
        );

        /// @dev Apply partition function.
        (input, outputs) = quantity.partition(
            input,
            outputs,
            order.fillThreshold
        );

        resolvedOrder = ResolvedOrder({
            info: order.info,
            input: input,
            outputs: outputs,
            sig: signedOrder.sig,
            hash: order.hash()
        });
        resolvedOrder.handleOverride(
            order.exclusiveFiller,
            order.decayStartTime,
            order.exclusivityOverrideBps
        );
    }

    /// @notice Resolves order into 'GladiusOrder' and applies a decay function.
    function resolve(
        SignedOrder calldata signedOrder
    ) internal view override returns (ResolvedOrder memory resolvedOrder) {
        GladiusOrder memory order = abi.decode(
            signedOrder.order,
            (GladiusOrder)
        );

        _validateOrder(order);

        /// @dev Apply decay function.
        InputToken memory input = order.input.decay(
            order.decayStartTime,
            order.decayEndTime
        );
        OutputToken[] memory outputs = order.outputs.decay(
            order.decayStartTime,
            order.decayEndTime
        );

        resolvedOrder = ResolvedOrder({
            info: order.info,
            input: input,
            outputs: outputs,
            sig: signedOrder.sig,
            hash: order.hash()
        });
        resolvedOrder.handleOverride(
            order.exclusiveFiller,
            order.decayStartTime,
            order.exclusivityOverrideBps
        );
    }    

    /// @inheritdoc BaseGladiusReactor
    function transferInputTokens(
        ResolvedOrder memory order,
        address to
    ) internal override {
        permit2.permitWitnessTransferFrom(
            order.toPermit(),
            order.transferDetails(to),
            order.info.swapper,
            order.hash,
            PartialFillLib.PERMIT2_ORDER_TYPE,
            order.sig
        );
    }

    /// @notice validate order fields:
    /// - outputs array must contain only 1 element.
    /// - deadline must be greater than or equal than decayEndTime
    /// - decayEndTime must be greater than or equal to decayStartTime
    /// - if there's input decay, outputs must not decay
    /// @dev Reverts if the order is invalid
    function _validateOrder(GladiusOrder memory order) internal pure {
        if (order.outputs.length != 1) revert InvalidOutLength();

        if (order.info.deadline < order.decayEndTime)
            revert DeadlineBeforeEndTime();

        if (order.decayEndTime < order.decayStartTime)
            revert OrderEndTimeBeforeStartTime();

        if (order.input.startAmount != order.input.endAmount) {
            if (order.outputs[0].startAmount != order.outputs[0].endAmount) {
                revert InputAndOutputDecay();
            }
        }
    }
}
