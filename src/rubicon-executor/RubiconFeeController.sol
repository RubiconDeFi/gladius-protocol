// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IProtocolFeeController} from "../interfaces/IProtocolFeeController.sol";
import {ResolvedOrder, OutputToken} from "../base/ReactorStructs.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DSAuth} from "../lib/DSAuth.sol";

/// @dev Rubicon's Protocol fee controller.
contract RubiconFeeController is IProtocolFeeController, DSAuth {
    uint256 private constant BPS = 100_000;
    uint256 public constant BASE_FEE = 30;
    address public feeRecipient;

    bool public initialized;

    struct Fee {
        // If true, apply either pair-based or base fee.
        bool applyFee;
        uint256 fee;
    }

    mapping(bytes32 => Fee) public fees;

    function initialize(address _owner, address _feeRecipient) external {
        require(!initialized, "initialized");
        owner = _owner;
        feeRecipient = _feeRecipient;

        initialized = true;
    }

    function getPairHash(
        address tokenIn,
        address tokenOut
    ) public view returns (bytes32 hash) {
        hash = keccak256(bytes.concat(bytes20(tokenIn), bytes20(tokenOut)));
    }

    /// @inheritdoc IProtocolFeeController
    function getFeeOutputs(
        ResolvedOrder memory order
    ) external view override returns (OutputToken[] memory result) {
        address tokenIn = address(order.input.token);
        /// @dev Take only 1 output token.
        address tokenOut = order.outputs[0].token;

        Fee memory fees = fees[getPairHash(address(tokenIn), tokenOut)];
        uint256 feeAmount;

        /// @dev Apply either base or pair-based fee.
        if (fees.applyFee) {
            feeAmount = fees.fee != 0
                ? (order.outputs[0].amount * fees.fee) / BPS
                : (order.outputs[0].amount * BASE_FEE) / BPS;

            result = new OutputToken[](1);
            result[0] = OutputToken({
                token: tokenOut,
                amount: feeAmount,
                recipient: feeRecipient
            });
        }

        uint256 size = result.length;

        assembly {
            // update array size to the actual number of unique fee outputs pairs
            // since the array was initialized with an upper bound of the total number of outputs
            // note: this leaves a few unused memory slots, but free memory pointer
            // still points to the next fresh piece of memory
            mstore(result, size)
        }
    }

    function setFee(
        address tokenIn,
        address tokenOut,
        uint256 fee,
        bool applyFee
    ) external auth {
        bytes32 pairHash = getPairHash(tokenIn, tokenOut);
        fees[pairHash] = Fee({applyFee: applyFee, fee: fee});
    }
}
