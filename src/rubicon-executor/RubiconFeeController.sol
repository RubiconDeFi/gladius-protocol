// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IProtocolFeeController} from "../interfaces/IProtocolFeeController.sol";
import {ResolvedOrder, OutputToken} from "../base/ReactorStructs.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DSAuth} from "../lib/DSAuth.sol";

/// @dev Rubicon's Protocol fee controller.
contract RubiconFeeController is IProtocolFeeController, DSAuth {
    uint256 private constant BPS = 100_000;
    uint256 public constant BASE_FEE = 10;
    address public feeRecipient;

    bool public initialized;

    struct Fee {
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

    /// @return hash - direction independent hash of the pair
    function getPairHash(
        address tokenIn,
        address tokenOut
    ) public pure returns (bytes32 hash) {
        address input = tokenIn > tokenOut ? tokenIn : tokenOut;
        address output = input == tokenIn ? tokenOut : tokenIn;

        hash = keccak256(bytes.concat(bytes20(input), bytes20(output)));
    }

    /// @inheritdoc IProtocolFeeController
    function getFeeOutputs(
        ResolvedOrder memory order
    ) external view override returns (OutputToken[] memory result) {
        result = new OutputToken[](order.outputs.length);

        address tokenIn = address(order.input.token);
        uint256 feeCount;

        for (uint256 i = 0; i < order.outputs.length; ++i) {
            address tokenOut = order.outputs[i].token;

            Fee memory fee = fees[getPairHash(address(tokenIn), tokenOut)];

            uint256 feeAmount = fee.applyFee
                ? (order.outputs[i].amount * fee.fee) / BPS
                : (order.outputs[i].amount * BASE_FEE) / BPS;

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

    function setFee(
        address tokenIn,
        address tokenOut,
        uint256 fee,
        bool applyFee
    ) external auth {
        bytes32 pairHash = getPairHash(tokenIn, tokenOut);
        fees[pairHash] = Fee({applyFee: applyFee, fee: fee});
    }

    function setFeeRecipient(address recipient) external auth {
        feeRecipient = recipient;
    }
}
