// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {DutchOutput, DutchInput, DutchOrderLib} from "./DutchOrderLib.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {InputToken, OutputToken} from "../base/ReactorStructs.sol";
import {OrderInfo} from "../base/ReactorStructs.sol";
import {DutchOrderLib} from "./DutchOrderLib.sol";
import {OrderInfoLib} from "./OrderInfoLib.sol";

struct ExclusiveDutchOrderWithPF {
    // generic order information
    OrderInfo info;
    // The time at which the DutchOutputs start decaying
    uint256 decayStartTime;
    // The time at which price becomes static
    uint256 decayEndTime;
    // The address who has exclusive rights to the order until decayStartTime
    address exclusiveFiller;
    // The amount in bps that a non-exclusive filler needs to improve the outputs by to be able to fill the order
    uint256 exclusivityOverrideBps;
    // The tokens that the swapper will provide when settling the order
    DutchInput input;
    // The tokens that must be received to satisfy the order
    DutchOutput[] outputs;
    // Minimum amount of output, to be received in a case of a partial fill.
    uint256 outputFillThreshold;
}

/// @dev Library for handling Dutch orders that can be partially filled.
library PartialFillLib {
    using FixedPointMathLib for uint256;
    using DutchOrderLib for DutchOutput[];
    using OrderInfoLib for OrderInfo;

    /// @notice Thrown, if calculated parts of in/out > initial amounts.
    error PartialFillOverflow();
    /// @notice Thrown, if calculated parts are equal to 0.
    error PartialFillUnderflow();
    /// @notice Thrown, if threshold isn't in a valid range.
    error InvalidThreshold();
    /// @notice Thrown, if amount to pay for an order, is less than set threshold.
    error SpendLtThreshold();
    /// @notice Thrown, when a rounding error, implies into a precision loss of >0.1%
    error RelativeErrTooBig();

    bytes internal constant EXCLUSIVE_DUTCH_PF_ORDER_TYPE =
        abi.encodePacked(
            "ExclusiveDutchOrderWithPF(",
            "OrderInfo info,",
            "uint256 decayStartTime,",
            "uint256 decayEndTime,",
            "address exclusiveFiller,",
            "uint256 exclusivityOverrideBps,",
            "address inputToken,",
            "uint256 inputStartAmount,",
            "uint256 inputEndAmount,",
            "DutchOutput[] outputs,",
            "uint256 outputFillThreshold)"
        );
    bytes internal constant ORDER_TYPE =
        abi.encodePacked(
            EXCLUSIVE_DUTCH_PF_ORDER_TYPE,
            DutchOrderLib.DUTCH_OUTPUT_TYPE,
            OrderInfoLib.ORDER_INFO_TYPE
        );
    bytes32 internal constant ORDER_TYPE_HASH = keccak256(ORDER_TYPE);

    /// @dev Note that sub-structs have to be defined in alphabetical order in the EIP-712 spec
    string internal constant PERMIT2_ORDER_TYPE =
        string(
            abi.encodePacked(
                "ExclusiveDutchOrderWithPF witness)",
                DutchOrderLib.DUTCH_OUTPUT_TYPE,
                EXCLUSIVE_DUTCH_PF_ORDER_TYPE,
                OrderInfoLib.ORDER_INFO_TYPE,
                DutchOrderLib.TOKEN_PERMISSIONS_TYPE
            )
        );

    /// @dev Returns parts of input/output amounts to execute.
    /// @param quantity - amount in the form of 'input.token' to buy from the order.
    /// @param input - 'InputToken' struct after applied decay fn.
    /// @param output - 'OutputToken[1]' struct after applied decay fn.
    /// @param outputFillThreshold - min amount out, that should be filled.
    function applyPartition(
        uint256 quantity,
        InputToken memory input,
        OutputToken[] memory output,
        uint256 outputFillThreshold
    ) internal view returns (InputToken memory, OutputToken[] memory) {
        _validateThreshold(outputFillThreshold, output[0].amount);

        uint256 spend = quantity.mulDivUp(output[0].amount, input.amount);

        _validatePartition(
            quantity,
            spend,
            input.amount,
            output[0].amount,
            outputFillThreshold
        );

        // Mutate amounts in structs.
        input.amount = quantity;
        output[0].amount = spend;

        return (input, output);
    }

    /// @dev Partition is valid if:
    ///      * {0 < q ≤ i}
    ///      * {t < s ≤ o}
    ///
    ///      t - outputFillThreshold
    ///      q - quantity
    ///      s - spend
    ///      i - order.input.amount
    ///      o - order.outputs[0].amount
    function _validatePartition(
        uint256 _quantity,
        uint256 _spend,
        uint256 _initIn,
        uint256 _initOut,
        uint256 _outputFillThreshold
    ) internal view {
        if (_quantity > _initIn || _spend > _initOut)
            revert PartialFillOverflow();
        if (_quantity == 0 || _spend == 0) revert PartialFillUnderflow();
        if (_spend < _outputFillThreshold) revert SpendLtThreshold();

        // Check for precision loss.
        uint256 _rem = (_quantity * _initOut) % _initIn;
        bool _isError = _rem * 1_000 >= _initIn * _quantity;

        if (_isError) revert RelativeErrTooBig();
    }

    /// @dev '_outputFillThreshold' is valid if:
    ///      * {0 ≤ t ≤ o}
    ///
    ///      t - outputFillThreshold
    ///      o - order.outputs[0].amount
    function _validateThreshold(
        uint256 _outputFillThreshold,
        uint256 _outAmt
    ) internal pure {
        if (_outputFillThreshold > _outAmt) revert InvalidThreshold();
    }

    /// @notice hash the given order
    /// @param order the order to hash
    /// @return the eip-712 order hash
    function hash(
        ExclusiveDutchOrderWithPF memory order
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    ORDER_TYPE_HASH,
                    order.info.hash(),
                    order.decayStartTime,
                    order.decayEndTime,
                    order.exclusiveFiller,
                    order.exclusivityOverrideBps,
                    order.input.token,
                    order.input.startAmount,
                    order.input.endAmount,
                    order.outputs.hash(),
                    order.outputFillThreshold
                )
            );
    }
}
