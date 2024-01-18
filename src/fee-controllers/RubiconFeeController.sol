// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IProtocolFeeController} from "../interfaces/IProtocolFeeController.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {ResolvedOrder, OutputToken} from "../base/ReactorStructs.sol";
import {ProxyConstructor} from "../lib/ProxyConstructor.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DSAuth} from "../lib/DSAuth.sol";

/// @dev Fee controller, that's intended to be called by reactors.
///      * By default applies constant 'BASE_FEE' on output token.
///      * Dynamic pair-based fee can be enabled by calling 'setPairBasedFee'.
///      * Both dynamic and base fee can be disabled by setting 'applyFee' to false.
contract RubiconFeeController is IProtocolFeeController, DSAuth, ProxyConstructor {
    using FixedPointMathLib for uint256;
    
    uint256 private constant DENOM = 100_000;
    uint256 public constant BASE_FEE = 10;
    address public feeRecipient;

    struct PairBasedFee {
        bool applyFee;
        uint256 fee;
    }

    /// @dev pair hash => pair-based fee
    mapping(bytes32 => PairBasedFee) public fees;

    function initialize(address _owner, address _feeRecipient) external override {
        if (initialized) revert AlreadyInitialized();
        owner = _owner;
        feeRecipient = _feeRecipient;

        initialized = true;
    }

    /// @return hash - direction independent hash of the pair.
    function getPairHash(
        address tokenIn,
        address tokenOut
    ) public pure returns (bytes32 hash) {
        address input = tokenIn > tokenOut ? tokenIn : tokenOut;
        address output = input == tokenIn ? tokenOut : tokenIn;

        hash = keccak256(bytes.concat(bytes20(input), bytes20(output)));
    }

    /// @inheritdoc IProtocolFeeController
    /// @notice Applies fee on output values in the form of output[0].token.
    function getFeeOutputs(
        ResolvedOrder memory order
    ) external view override returns (OutputToken[] memory result) {
	/// @notice Right now the length is enforced by
	///         'GladiusReactor' to be equal to 1.
        result = new OutputToken[](order.outputs.length);

        address tokenIn = address(order.input.token);
        uint256 feeCount;

        for (uint256 i = 0; i < order.outputs.length; ++i) {
	    /// @dev Wee will be in its form.
            address tokenOut = order.outputs[i].token;

            PairBasedFee memory fee = fees[getPairHash(address(tokenIn), tokenOut)];

            uint256 feeAmount = fee.applyFee
                ? order.outputs[i].amount.mulDivUp(fee.fee, DENOM)
                : order.outputs[i].amount.mulDivUp(BASE_FEE, DENOM);

            /// @dev If fee is applied to pair.
            if (feeAmount != 0) {
                bool found;

                for (uint256 j = 0; j < feeCount; ++j) {
                    OutputToken memory feeOutput = result[j];

                    if (feeOutput.token == tokenOut) {
                        found = true;
                        feeOutput.amount += feeAmount;
                    }
                }

                if (!found) {
                    result[feeCount] = OutputToken({
                        token: tokenOut,
                        amount: feeAmount,
                        recipient: feeRecipient
                    });
                    feeCount++;
                }
            }
        }

        assembly {
            // update array size to the actual number of unique fee outputs pairs
            // since the array was initialized with an upper bound of the total number of outputs
            // note: this leaves a few unused memory slots, but free memory pointer
            // still points to the next fresh piece of memory
            mstore(result, feeCount)
        }
    }

    //---------------------------- ADMIN ----------------------------

    function setPairBasedFee(
        address tokenIn,
        address tokenOut,
        uint256 fee,
        bool applyFee
    ) external auth {
        bytes32 pairHash = getPairHash(tokenIn, tokenOut);
        fees[pairHash] = PairBasedFee({applyFee: applyFee, fee: fee});
    }

    function setFeeRecipient(address recipient) external auth {
        feeRecipient = recipient;
    }
}
