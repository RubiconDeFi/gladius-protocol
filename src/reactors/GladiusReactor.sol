// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {SignedOrder, ResolvedOrder, InputToken, OutputToken} from "../base/ReactorStructs.sol";
import {ExclusiveDutchOrder, ExclusiveDutchOrderLib, DutchOutput, DutchInput} from "../lib/ExclusiveDutchOrderLib.sol";
import {PartialFillLib, ExclusiveDutchOrderWithPF} from "../lib/PartialFillLib.sol";
import {ExclusiveDutchOrderReactor} from "./ExclusiveDutchOrderReactor.sol";
import {ExclusivityOverrideLib} from "../lib/ExclusivityOverrideLib.sol";
import {DutchDecayLib} from "../lib/DutchDecayLib.sol";
import {Permit2Lib} from "../lib/Permit2Lib.sol";
import {BaseReactor} from "./BaseReactor.sol";

/// @notice Reactor for exclusive dutch orders, with some modifications:
///         - Supports partial fills.
///         - Allows only 1 output per 1 input.
contract GladiusReactor is BaseReactor {
    using PartialFillLib for ExclusiveDutchOrderWithPF;
    using ExclusivityOverrideLib for ResolvedOrder;
    using DutchDecayLib for DutchOutput[];
    using DutchDecayLib for DutchInput;
    using Permit2Lib for ResolvedOrder;
    using PartialFillLib for uint256;

    /// @notice thrown when 'outputs' array has >1 length.
    error InvalidOutLength();
    /// @notice thrown when an order's deadline is before its end time
    error DeadlineBeforeEndTime();
    /// @notice thrown when an order's end time is before its start time
    error OrderEndTimeBeforeStartTime();
    /// @notice thrown when an order's inputs and outputs both decay
    error InputAndOutputDecay();

    function getPayAmount(
        SignedOrder calldata signedOrder
    ) external view returns (uint256 spend) {
        spend = resolve(signedOrder).outputs[0].amount;
    }

    /// @notice Resolves order into an Exclusive Dutch order. With applied
    ///         decay function and partition function on in/out amounts.
    /// @notice 'signedOrder.order' = abi.encode(order, quantity).
    ///          * order    - abi encoded 'ExclusiveDutchOrderWithPF'.
    ///          * quantity - uint256 amount to buy from the 'order'
    ///                       in the form of 'order.input.token'.
    function resolve(
        SignedOrder calldata signedOrder
    ) internal view override returns (ResolvedOrder memory resolvedOrder) {
        /// @dev 'signedOrder.order' should be encoded on a client-side,
        ///      by the executor of this order.
        (ExclusiveDutchOrderWithPF memory order, uint256 quantity) = abi.decode(
            signedOrder.order,
            (ExclusiveDutchOrderWithPF, uint256)
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
        (input, outputs) = quantity.applyPartition(
            input,
            outputs,
            order.outputFillThreshold
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

    /// @inheritdoc BaseReactor
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
    /// - for input decay, startAmount must < endAmount
    /// @dev Reverts if the order is invalid
    function _validateOrder(
        ExclusiveDutchOrderWithPF memory order
    ) internal pure {
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
