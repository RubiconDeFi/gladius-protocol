// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {CurrencyLibrary} from "../../../src/lib/CurrencyLibrary.sol";
import {ResolvedOrder, OutputToken, SignedOrder} from "../../../src/base/ReactorStructs.sol";
import {BaseGladiusReactor} from "../../../src/reactors/BaseGladiusReactor.sol";
import {IGladiusReactor} from "../../../src/interfaces/IGladiusReactor.sol";
import {IReactorCallback} from "../../../src/interfaces/IReactorCallback.sol";

contract MockGladiusFill is IReactorCallback {
    using CurrencyLibrary for address;

    IGladiusReactor immutable reactor;

    constructor(address _reactor) {
        reactor = IGladiusReactor(_reactor);
    }

    /// @notice assume that we already have all output tokens
    function execute(SignedOrder calldata order, uint256 quantity) external {
        reactor.executeWithCallback(order, quantity, hex"");
    }

    /// @notice assume that we already have all output tokens
    function executeBatch(
        SignedOrder[] calldata orders,
        uint256[] calldata quantities
    ) external {
        reactor.executeBatchWithCallback(orders, quantities, hex"");
    }

    /// @notice assume that we already have all output tokens
    function reactorCallback(
        ResolvedOrder[] memory resolvedOrders,
        bytes memory
    ) external {
        for (uint256 i = 0; i < resolvedOrders.length; i++) {
            for (uint256 j = 0; j < resolvedOrders[i].outputs.length; j++) {
                OutputToken memory output = resolvedOrders[i].outputs[j];
                if (output.token.isNative()) {
                    CurrencyLibrary.transferNative(
                        address(reactor),
                        output.amount
                    );
                } else {
                    ERC20(output.token).approve(
                        address(reactor),
                        type(uint256).max
                    );
                }
            }
        }
    }
}
