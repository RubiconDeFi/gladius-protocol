// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Owned} from "solmate/src/auth/Owned.sol";
import {Test} from "forge-std/Test.sol";
import {InputToken, OutputToken, OrderInfo, ResolvedOrder, SignedOrder} from "../../src/base/ReactorStructs.sol";
import {NATIVE} from "../../src/lib/CurrencyLibrary.sol";
import {ProtocolFees} from "../../src/base/ProtocolFees.sol";
import {ResolvedOrderLib} from "../../src/lib/ResolvedOrderLib.sol";
import {MockERC20} from "../util/mock/MockERC20.sol";
import {OrderInfoBuilder} from "../util/OrderInfoBuilder.sol";
import {OutputsBuilder} from "../util/OutputsBuilder.sol";
import {MockProtocolFees} from "../util/mock/MockProtocolFees.sol";
import {PermitSignature} from "../util/PermitSignature.sol";
import {DeployPermit2} from "../util/DeployPermit2.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {MockFillContract} from "../util/mock/MockFillContract.sol";
import {RubiconFeeController} from "../../src/rubicon-executor/RubiconFeeController.sol";
import {ExclusiveDutchOrderReactor, ExclusiveDutchOrder, DutchInput, DutchOutput} from "../../src/reactors/ExclusiveDutchOrderReactor.sol";

contract RubiconFeeControllerTest is Test {
    using OrderInfoBuilder for OrderInfo;
    using ResolvedOrderLib for OrderInfo;

    event ProtocolFeeControllerSet(
        address oldFeeController,
        address newFeeController
    );

    address constant PROTOCOL_FEE_OWNER = address(11);
    address constant RECIPIENT = address(12);
    address constant SWAPPER = address(13);

    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockERC20 tokenOut2;
    MockProtocolFees fees;
    RubiconFeeController feeController;

    function setUp() public {
        fees = new MockProtocolFees(PROTOCOL_FEE_OWNER);
        tokenIn = new MockERC20("Input", "IN", 18);
        tokenOut = new MockERC20("Output", "OUT", 18);
        tokenOut2 = new MockERC20("Output2", "OUT", 18);
        feeController = new RubiconFeeController();
        feeController.initialize(PROTOCOL_FEE_OWNER, RECIPIENT);

        vm.prank(PROTOCOL_FEE_OWNER);
        fees.setProtocolFeeController(address(feeController));
    }

    function testSetFeeController() public {
        assertEq(address(fees.feeController()), address(feeController));
        vm.expectEmit(true, true, false, false);
        emit ProtocolFeeControllerSet(address(feeController), address(2));

        vm.prank(PROTOCOL_FEE_OWNER);
        fees.setProtocolFeeController(address(2));
        assertEq(address(fees.feeController()), address(2));
    }

    function testSetFeeControllerAuth() public {
        assertEq(address(fees.feeController()), address(feeController));
        vm.prank(address(1));
        vm.expectRevert("UNAUTHORIZED");
        fees.setProtocolFeeController(address(2));
        assertEq(address(fees.feeController()), address(feeController));
    }

    function testTakeFeesNoFees() public {
        ResolvedOrder memory order = createOrder(1 ether, false);

        assertEq(order.outputs.length, 1);
        vm.prank(PROTOCOL_FEE_OWNER);
        feeController.setFee(address(tokenIn), address(tokenOut), 0, true);
        ResolvedOrder memory afterFees = fees.takeFees(order);
        assertEq(afterFees.outputs.length, 1);
        assertEq(afterFees.outputs[0].token, order.outputs[0].token);
        assertEq(afterFees.outputs[0].amount, order.outputs[0].amount);
        assertEq(afterFees.outputs[0].recipient, order.outputs[0].recipient);
    }

    function testPairBasedFee() public {
        ResolvedOrder memory order = createOrder(1 ether, false);
        uint256 feeBps = 3;
        /// @dev Apply pair-based fee.
        vm.prank(PROTOCOL_FEE_OWNER);
        feeController.setFee(address(tokenIn), address(tokenOut), feeBps, true);

        assertEq(order.outputs.length, 1);
        ResolvedOrder memory afterFees = fees.takeFees(order);

        assertEq(afterFees.outputs.length, 2);
        assertEq(afterFees.outputs[0].token, order.outputs[0].token);
        assertEq(afterFees.outputs[0].amount, order.outputs[0].amount);
        assertEq(afterFees.outputs[0].recipient, order.outputs[0].recipient);
        assertEq(afterFees.outputs[1].token, order.outputs[0].token);
        assertEq(
            afterFees.outputs[1].amount,
            (order.outputs[0].amount * feeBps) / 100_000
        );
        assertEq(afterFees.outputs[1].recipient, RECIPIENT);
    }

    function testBaseFee() public {
        ResolvedOrder memory order = createOrder(1 ether, false);
        /// @dev Enable fee, but apply only BASE_FEE.
        vm.prank(PROTOCOL_FEE_OWNER);

        assertEq(order.outputs.length, 1);
        ResolvedOrder memory afterFees = fees.takeFees(order);

        assertEq(afterFees.outputs.length, 2);
        assertEq(afterFees.outputs[0].token, order.outputs[0].token);
        assertEq(afterFees.outputs[0].amount, order.outputs[0].amount);
        assertEq(afterFees.outputs[0].recipient, order.outputs[0].recipient);
        assertEq(afterFees.outputs[1].token, order.outputs[0].token);
        assertEq(
            afterFees.outputs[1].amount,
            (order.outputs[0].amount * feeController.BASE_FEE()) / 100_000
        );
        assertEq(afterFees.outputs[1].recipient, RECIPIENT);
    }

    function createOrder(
        uint256 amount,
        bool isEthOutput
    ) private view returns (ResolvedOrder memory) {
        OutputToken[] memory outputs = new OutputToken[](1);
        address outputToken = isEthOutput ? NATIVE : address(tokenOut);
        outputs[0] = OutputToken(outputToken, amount, SWAPPER);
        return
            ResolvedOrder({
                info: OrderInfoBuilder.init(address(0)),
                input: InputToken(tokenIn, 1 ether, 1 ether),
                outputs: outputs,
                sig: hex"00",
                hash: bytes32(0)
            });
    }
}
