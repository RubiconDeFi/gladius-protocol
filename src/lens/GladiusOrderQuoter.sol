// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {OrderInfo, ResolvedOrder, SignedOrder} from "../base/ReactorStructs.sol";
import {IReactorCallback} from "../interfaces/IReactorCallback.sol";
import {IGladiusReactor} from "../interfaces/IGladiusReactor.sol";

/// @notice Quoter contract for orders
/// @dev Meant to be used as an off-chain lens contract to pre-validate generic orders.
contract GladiusOrderQuoter is IReactorCallback {
    /// @notice Thrown if reactorCallback receives more than one order.
    error OrdersLengthIncorrect();

    uint256 constant ORDER_INFO_OFFSET = 64;

    /// @notice Quote the given order, returning the 'ResolvedOrder' object which defines
    ///         the current input and output token amounts required to satisfy it
    ///         Also bubbles up any reverts that would occur
    ///         during the processing of the order.
    /// @param order abi-encoded order, including `reactor` as the first
    ///        encoded struct member
    /// @param sig The order signature
    /// @param quantity Gladius-specific param, that specifies part of the
    ///        'input.amount to take from an 'order'
    /// @return result The ResolvedOrder
    function quote(
        bytes memory order,
        bytes memory sig,
        uint256 quantity
    ) external returns (ResolvedOrder memory result) {
        try
            getReactor(order).executeWithCallback(
                SignedOrder(order, sig),
                quantity,
                bytes("")
            )
        {} catch (bytes memory reason) {
            result = parseRevertReason(reason);
        }
    }

    /// @notice Return the reactor of a given order (abi.encoded bytes).
    /// @param order abi-encoded order, including `reactor` as the first encoded struct member
    /// @return reactor
    function getReactor(
        bytes memory order
    ) public pure returns (IGladiusReactor reactor) {
        assembly {
            let orderInfoOffsetPointer := add(order, ORDER_INFO_OFFSET)
            reactor := mload(
                add(orderInfoOffsetPointer, mload(orderInfoOffsetPointer))
            )
        }
    }

    /// @notice Return the order info of a given order (abi-encoded bytes).
    /// @param reason The revert reason
    /// @return order abi-encoded order, including `reactor` as the first encoded struct member
    function parseRevertReason(
        bytes memory reason
    ) private pure returns (ResolvedOrder memory order) {
        if (reason.length < 192) {
            assembly {
                revert(add(32, reason), mload(reason))
            }
        } else {
            return abi.decode(reason, (ResolvedOrder));
        }
    }

    /// @notice Reactor callback function
    /// @dev reverts with the resolved order as reason
    /// @param resolvedOrders The resolved orders
    function reactorCallback(
        ResolvedOrder[] memory resolvedOrders,
        bytes memory
    ) external pure {
        if (resolvedOrders.length != 1) {
            revert OrdersLengthIncorrect();
        }
        bytes memory order = abi.encode(resolvedOrders[0]);
        assembly {
            revert(add(32, order), mload(order))
        }
    }
}
