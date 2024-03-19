// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ResolvedOrder, OutputToken, SignedOrder} from "../../../src/base/ReactorStructs.sol";
import {IReactorCallback} from "../../../src/interfaces/IReactorCallback.sol";
import {IGladiusReactor} from "../../../src/interfaces/IGladiusReactor.sol";
import {CurrencyLibrary} from "../../../src/lib/CurrencyLibrary.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract MockFillContractDoubleExecutionGladius is IReactorCallback {
    using CurrencyLibrary for address;

    IGladiusReactor immutable reactor1;
    IGladiusReactor immutable reactor2;

    bool public exec = false;

    constructor(address _reactor1, address _reactor2) {
        reactor1 = IGladiusReactor(_reactor1);
        reactor2 = IGladiusReactor(_reactor2);
    }

    modifier executing() {
	if (!exec) {
	    exec = true;
	    _;
	} else {
	    exec = false;
	    _;	  
	}
    }

    /// @notice assume that we already have all output tokens
    function execute(
        SignedOrder calldata order,
        SignedOrder calldata other,
        uint256 quantity0,
        uint256 quantity1
    ) external {
        reactor1.executeWithCallback(
            order,
            quantity0,
            abi.encode(other, quantity1)
        );
    }

    /// @notice assume that we already have all output tokens
    function execute(
        SignedOrder calldata order,
        SignedOrder calldata other
    ) external {
        reactor2.executeWithCallback(
            order,
            abi.encode(other)
        );
    }    

    /// @notice assume that we already have all output tokens
    function reactorCallback(
        ResolvedOrder[] memory resolvedOrders,
        bytes memory otherSignedOrder
    ) external executing {
        for (uint256 i = 0; i < resolvedOrders.length; i++) {
            for (uint256 j = 0; j < resolvedOrders[i].outputs.length; j++) {
                OutputToken memory output = resolvedOrders[i].outputs[j];
                if (output.token.isNative()) {
                    CurrencyLibrary.transferNative(msg.sender, output.amount);
                } else {
                    ERC20(output.token).approve(msg.sender, type(uint256).max);
                }
            }
        }

        if (msg.sender == address(reactor1) && exec) {
            (SignedOrder memory o, uint256 q) = abi.decode(
                otherSignedOrder,
                (SignedOrder, uint256)
            );
            reactor2.executeWithCallback(o, q, hex"");
        } else if (msg.sender == address(reactor2) && exec) {
            (SignedOrder memory o) = abi.decode(
                otherSignedOrder,
                (SignedOrder)
            );
            reactor1.executeWithCallback(o, hex"");
        }
    }
}
