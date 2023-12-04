// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {DeployPermit2} from "../util/DeployPermit2.sol";
import {ExclusiveDutchOrder, ResolvedOrder, DutchOutput, DutchInput, BaseReactor} from "../../src/reactors/ExclusiveDutchOrderReactor.sol";
import {OrderInfo, InputToken, SignedOrder, OutputToken} from "../../src/base/ReactorStructs.sol";
import {GladiusReactor} from "../../src/reactors/GladiusReactor.sol";
import {DutchDecayLib} from "../../src/lib/DutchDecayLib.sol";
import {CurrencyLibrary, NATIVE} from "../../src/lib/CurrencyLibrary.sol";
import {OrderInfoBuilder} from "../util/OrderInfoBuilder.sol";
import {MockERC20} from "../util/mock/MockERC20.sol";
import {ExclusiveDutchOrderLib} from "../../src/lib/ExclusiveDutchOrderLib.sol";
import {PartialFillLib, ExclusiveDutchOrderWithPF} from "../../src/lib/PartialFillLib.sol";
import {OutputsBuilder} from "../util/OutputsBuilder.sol";
import {MockFillContract} from "../util/mock/MockFillContract.sol";
import {MockFillContractWithOutputOverride} from "../util/mock/MockFillContractWithOutputOverride.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {PermitSignature} from "../util/PermitSignature.sol";
import {ReactorEvents} from "../../src/base/ReactorEvents.sol";
import {BaseReactorTest} from "../base/BaseReactor.t.sol";

import {console} from "forge-std/console.sol";

contract GladiusReactorTest is PermitSignature, DeployPermit2, BaseReactorTest {
    using ExclusiveDutchOrderLib for ExclusiveDutchOrder;
    using PartialFillLib for ExclusiveDutchOrderWithPF;
    using DutchDecayLib for DutchOutput[];
    using FixedPointMathLib for uint256;
    using OrderInfoBuilder for OrderInfo;
    using DutchDecayLib for DutchInput;
    using PartialFillLib for uint256;

    // Default min. fill threshold.
    uint256 constant MIN_FT = 1;
    uint256 swapper2Pk = 0x1337a228b322c69d420e;
    address swapper2 = vm.addr(swapper2Pk);

    uint256 public inputAmount = 100e6;
    uint256 public outputAmount = 5e18;
    // min. fill - 25 out of 50
    uint256 public outputFillThreshold = 25e17;
    // buy 90 tokens out of 100.
    uint256 public quantity = 90e6;

    uint256 public halfBidInput = outputAmount / 2;
    uint256 public halfBidOutput = inputAmount / 2;

    function name() public pure override returns (string memory) {
        return "ExclusiveDutchOrderWithPF";
    }

    function createReactor() public override returns (BaseReactor) {
        BaseReactor r = new GladiusReactor();
        r.initialize(permit2, PROTOCOL_FEE_OWNER);

        return r;
    }

    /// @dev Create and sign 'ExclusiveDutchOrderWithPF'
    function createAndSignOrder(
        ResolvedOrder memory request
    )
        public
        view
        override
        returns (SignedOrder memory signedOrder, bytes32 orderHash)
    {
        DutchOutput[] memory outputs = new DutchOutput[](
            request.outputs.length
        );

        for (uint256 i = 0; i < request.outputs.length; i++) {
            OutputToken memory output = request.outputs[i];
            outputs[i] = DutchOutput({
                token: output.token,
                startAmount: output.amount,
                endAmount: output.amount,
                recipient: output.recipient
            });
        }

        ExclusiveDutchOrderWithPF memory order = ExclusiveDutchOrderWithPF({
            info: request.info,
            decayStartTime: block.timestamp,
            decayEndTime: request.info.deadline,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 300,
            input: DutchInput(
                request.input.token,
                request.input.amount,
                request.input.amount
            ),
            outputs: outputs,
            outputFillThreshold: MIN_FT
        });
        orderHash = order.hash();

        // buy half of the input amount.
        uint256 quantity = request.input.amount / 2;

        return (
            SignedOrder(
                abi.encode(order, quantity),
                signOrder(swapperPrivateKey, address(permit2), order)
            ),
            orderHash
        );
    }

    function testExecuteBatchFillDiffOrders() public {
        ExclusiveDutchOrderWithPF memory ask = ExclusiveDutchOrderWithPF({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 300,
            input: DutchInput(tokenIn, inputAmount, inputAmount),
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                outputAmount,
                outputAmount,
                swapper
            ),
            outputFillThreshold: MIN_FT
        });

        uint256 bidInput = outputAmount / 2;
        uint256 bidOutput = inputAmount / 2;

        /*
	  2 orders in the book, that will
	  be matched together.	  
	  ------------------------------
	  |         ORDER-BOOK         |
	  ------------------------------
	  | (X/Y (sell 100)   (buy 5)) |
	  |                            |
	  | (Y/X (sell 2.5)  (buy 50)) |
	  | (Y/X (sell 2.5)  (buy 50)) |
	  ------------------------------
	*/

        ExclusiveDutchOrderWithPF memory bid = ExclusiveDutchOrderWithPF({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper2)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 300,
            input: DutchInput(tokenOut, bidInput, bidInput),
            outputs: OutputsBuilder.singleDutch(
                address(tokenIn),
                bidOutput,
                bidOutput,
                swapper2
            ),
            outputFillThreshold: MIN_FT
        });

        tokenIn.mint(address(swapper), inputAmount);
        tokenOut.mint(address(swapper2), bidInput);

        tokenIn.forceApprove(swapper, address(permit2), inputAmount);
        tokenOut.forceApprove(swapper2, address(permit2), bidInput);

        uint256 swapperBalanceIN_0 = tokenIn.balanceOf(swapper);
        uint256 swapper2BalanceOUT_0 = tokenOut.balanceOf(swapper2);

        uint256 swapperBalanceOUT_0 = tokenOut.balanceOf(swapper);
        uint256 swapper2BalanceIN_0 = tokenIn.balanceOf(swapper2);

        SignedOrder[] memory orders = new SignedOrder[](2);

        orders[0] = generateSignedOrder(ask, bidOutput);
        orders[1] = generateSignedOrderWithPk(bid, bidInput, swapper2Pk);

        fillContract.executeBatch(orders);

        //;;;;;;;;;;;;;;;;;;;; SWAPPER ASSERTIONS ;;;;;;;;;;;;;;;;;;;;
        /*assertEq(
            (swapperBalanceIN_0 - tokenIn.balanceOf(swapper)),
            inputAmount
        );
        assertEq(
            (tokenOut.balanceOf(swapper) - swapperBalanceOUT_0),
            outputAmount
        );

        //;;;;;;;;;;;;;;;;;;;; SWAPPER_2 ASSERTIONS ;;;;;;;;;;;;;;;;;;;;
        assertEq(
            (swapper2BalanceOUT_0 - tokenOut.balanceOf(swapper2)),
            outputAmount
        );
        assertEq(
            (tokenIn.balanceOf(swapper2) - swapper2BalanceIN_0),
            inputAmount
        );*/
    }

    function testExecuteBatchFill() public {
        ExclusiveDutchOrderWithPF memory ask = ExclusiveDutchOrderWithPF({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 300,
            input: DutchInput(tokenIn, inputAmount, inputAmount),
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                outputAmount,
                outputAmount,
                swapper
            ),
            outputFillThreshold: MIN_FT
        });

        ExclusiveDutchOrderWithPF memory bid = ExclusiveDutchOrderWithPF({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper2)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 300,
            input: DutchInput(tokenOut, outputAmount, outputAmount),
            outputs: OutputsBuilder.singleDutch(
                address(tokenIn),
                inputAmount,
                inputAmount,
                swapper2
            ),
            outputFillThreshold: MIN_FT
        });

        tokenIn.mint(address(swapper), inputAmount);
        tokenOut.mint(address(swapper2), outputAmount);

        tokenIn.forceApprove(swapper, address(permit2), inputAmount);
        tokenOut.forceApprove(swapper2, address(permit2), outputAmount);

        uint256 swapperBalanceIN_0 = tokenIn.balanceOf(swapper);
        uint256 swapper2BalanceOUT_0 = tokenOut.balanceOf(swapper2);

        uint256 swapperBalanceOUT_0 = tokenOut.balanceOf(swapper);
        uint256 swapper2BalanceIN_0 = tokenIn.balanceOf(swapper2);

        SignedOrder[] memory orders = new SignedOrder[](2);
        orders[0] = generateSignedOrder(ask, inputAmount);
        orders[1] = generateSignedOrderWithPk(bid, outputAmount, swapper2Pk);

        fillContract.executeBatch(orders);

        //;;;;;;;;;;;;;;;;;;;; SWAPPER ASSERTIONS ;;;;;;;;;;;;;;;;;;;;
        assertEq(
            (swapperBalanceIN_0 - tokenIn.balanceOf(swapper)),
            inputAmount
        );
        assertEq(
            (tokenOut.balanceOf(swapper) - swapperBalanceOUT_0),
            outputAmount
        );

        //;;;;;;;;;;;;;;;;;;;; SWAPPER_2 ASSERTIONS ;;;;;;;;;;;;;;;;;;;;
        assertEq(
            (swapper2BalanceOUT_0 - tokenOut.balanceOf(swapper2)),
            outputAmount
        );
        assertEq(
            (tokenIn.balanceOf(swapper2) - swapper2BalanceIN_0),
            inputAmount
        );
    }

    function testExecutePartialFill() public {
        ExclusiveDutchOrderWithPF memory order = ExclusiveDutchOrderWithPF({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 300,
            input: DutchInput(tokenIn, inputAmount, inputAmount),
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                outputAmount,
                outputAmount,
                swapper
            ),
            outputFillThreshold: outputFillThreshold
        });

        InputToken memory input = order.input.decay(
            order.decayStartTime,
            order.decayEndTime
        );
        OutputToken[] memory outputs = order.outputs.decay(
            order.decayStartTime,
            order.decayEndTime
        );

        // Amounts, that should be spent.
        (InputToken memory inPf, OutputToken[] memory outPf) = quantity
            .applyPartition(input, outputs, outputFillThreshold);

        // Exchange rate always remains the same.
        uint256 r = (input.amount.divWadUp(outputs[0].amount));
        assertEq(r, inPf.amount.divWadUp(outPf[0].amount));

        // Amounts after 'applyPartition' can't be gt init amt.
        assertLe(inPf.amount, input.amount);
        assertLe(outPf[0].amount, outputs[0].amount);

        tokenIn.mint(address(swapper), inputAmount);
        tokenOut.mint(address(fillContract), outPf[0].amount);
        tokenIn.forceApprove(swapper, address(permit2), inputAmount);

        uint256 swapperBalanceIN_0 = tokenIn.balanceOf(swapper);
        uint256 fillerBalanceIN_0 = tokenIn.balanceOf(address(fillContract));

        uint256 swapperBalanceOUT_0 = tokenOut.balanceOf(swapper);
        uint256 fillerBalanceOUT_0 = tokenOut.balanceOf(address(fillContract));

        // Executing order here yo!!
        fillContract.execute(generateSignedOrder(order, quantity));

        //;;;;;;;;;;;;;;;;;;;; SWAPPER ASSERTIONS ;;;;;;;;;;;;;;;;;;;;
        assertEq(
            (swapperBalanceIN_0 - tokenIn.balanceOf(swapper)),
            inPf.amount
        );
        assertEq(
            (tokenOut.balanceOf(swapper) - swapperBalanceOUT_0),
            outPf[0].amount
        );

        //;;;;;;;;;;;;;;;;;;;; FILLER ASSERTIONS ;;;;;;;;;;;;;;;;;;;;
        assertEq(
            (tokenIn.balanceOf(address(fillContract)) - fillerBalanceIN_0),
            inPf.amount
        );
        assertEq(
            (fillerBalanceOUT_0 - tokenOut.balanceOf(address(fillContract))),
            outPf[0].amount
        );
    }

    /*
    function testFuzzExecutePartialFill(
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 quantity,
        uint256 outputFillThreshold
    ) public {
        outputFillThreshold = bound(outputFillThreshold, 100, PartialFillLib.BPS);
        // 'pb' can't be lt 'ftb'
        partBps = bound(partBps, outputFillThreshold, PartialFillLib.BPS);

        inputAmount = bound(inputAmount, 1e4, type(uint128).max);
        outputAmount = bound(outputAmount, 1e4, type(uint128).max);

        tokenIn.mint(address(swapper), inputAmount);
        tokenOut.mint(address(fillContract), outputAmount);
        tokenIn.forceApprove(swapper, address(permit2), inputAmount);

        ExclusiveDutchOrderWithPF memory order = ExclusiveDutchOrderWithPF({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 300,
            input: DutchInput(tokenIn, inputAmount, inputAmount),
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                outputAmount,
                outputAmount,
                swapper
            ),
            outputFillThreshold: outputFillThreshold
        });

        InputToken memory input = order.input.decay(
            order.decayStartTime,
            order.decayEndTime
        );
        OutputToken[] memory outputs = order.outputs.decay(
            order.decayStartTime,
            order.decayEndTime
        );

        // Amounts, that should be spent.
        (InputToken memory inPf, OutputToken[] memory outPf) = partBps
            .applyPartition(input, outputs, outputFillThreshold);

        // Exchange rate remains the same.
        uint256 r = (input.amount.divWadUp(outputs[0].amount));
        assertEq(r, inPf.amount.divWadUp(outPf[0].amount));

        // Amounts after 'applyPartition' can't be gt init amt.
        assertLe(inPf.amount, input.amount);
        assertLe(outPf[0].amount, outputs[0].amount);

        uint256 swapperBalanceIN_0 = tokenIn.balanceOf(swapper);
        uint256 fillerBalanceIN_0 = tokenIn.balanceOf(address(fillContract));

        uint256 swapperBalanceOUT_0 = tokenOut.balanceOf(swapper);
        uint256 fillerBalanceOUT_0 = tokenOut.balanceOf(address(fillContract));

        SignedOrder memory sigo = generateSignedOrder(order, partBps);
        // Executing order here yo!!
        fillContract.execute(sigo);

        //;;;;;;;;;;;;;;;;;;;; SWAPPER ASSERTIONS ;;;;;;;;;;;;;;;;;;;;
        assertEq(
            (swapperBalanceIN_0 - tokenIn.balanceOf(swapper)),
            inPf.amount
        );
        assertEq(
            (tokenOut.balanceOf(swapper) - swapperBalanceOUT_0),
            outPf[0].amount
        );

        //;;;;;;;;;;;;;;;;;;;; FILLER ASSERTIONS ;;;;;;;;;;;;;;;;;;;;
        assertEq(
            (tokenIn.balanceOf(address(fillContract)) - fillerBalanceIN_0),
            inPf.amount
        );
        assertEq(
            (fillerBalanceOUT_0 - tokenOut.balanceOf(address(fillContract))),
            outPf[0].amount
        );
    }*/

    /*
    function testInvalidPartBpsData() public {
        uint256 inputAmount = 1e18;
        uint256 outputAmount = 2e18;

        ExclusiveDutchOrderWithPF memory order = ExclusiveDutchOrderWithPF({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 300,
            input: DutchInput(tokenIn, inputAmount, inputAmount),
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                outputAmount,
                outputAmount,
                swapper
            ),
            outputFillThreshold: MIN_PF
        });

        fillContract.execute(_invalidAbiEncode(order));
    }

    // Execute order, with 0 (in && out) amts, to trigger 'PartialFillUnderflow' err.
    function testPartialFillUnderflow() public {
        uint256 inputAmount = 0;
        uint256 outputAmount = 0;

        ExclusiveDutchOrderWithPF memory order = ExclusiveDutchOrderWithPF({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 300,
            input: DutchInput(tokenIn, inputAmount, inputAmount),
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                outputAmount,
                outputAmount,
                swapper
            ),
            outputFillThreshold: MIN_FT
        });

        vm.expectRevert(bytes4(keccak256("PartialFillUnderflow()")));
        fillContract.execute(generateSignedOrder(order, DEFAULT_PART_BPS));
    }*/

    function generateSignedOrder(
        ExclusiveDutchOrderWithPF memory order,
        uint256 quantity
    ) private view returns (SignedOrder memory result) {
        bytes memory sig = signOrder(
            swapperPrivateKey,
            address(permit2),
            order
        );
        result = SignedOrder(abi.encode(order, quantity), sig);
    }

    function generateSignedOrderWithPk(
        ExclusiveDutchOrderWithPF memory order,
        uint256 quantity,
        uint256 privateKey
    ) internal view returns (SignedOrder memory result) {
        bytes memory sig = signOrder(privateKey, address(permit2), order);
        result = SignedOrder(abi.encode(order, quantity), sig);
    }

    //============================ ORDERS ============================

    function ask()
        internal
        view
        returns (ExclusiveDutchOrderWithPF memory order)
    {
        order = ExclusiveDutchOrderWithPF({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 300,
            input: DutchInput(tokenIn, inputAmount, inputAmount),
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                outputAmount,
                outputAmount,
                swapper
            ),
            outputFillThreshold: outputFillThreshold
        });
    }

    function bid()
        internal
        view
        returns (ExclusiveDutchOrderWithPF memory order)
    {
        order = ExclusiveDutchOrderWithPF({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper2)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 300,
            input: DutchInput(tokenOut, outputAmount, outputAmount),
            outputs: OutputsBuilder.singleDutch(
                address(tokenIn),
                inputAmount,
                inputAmount,
                swapper2
            ),
            outputFillThreshold: MIN_FT
        });
    }

    function halfBid()
        internal
        view
        returns (ExclusiveDutchOrderWithPF memory order)
    {
        order = ExclusiveDutchOrderWithPF({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper2)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 300,
            input: DutchInput(tokenOut, outputAmount, outputAmount),
            outputs: OutputsBuilder.singleDutch(
                address(tokenIn),
                inputAmount,
                inputAmount,
                swapper2
            ),
            outputFillThreshold: MIN_FT
        });
    }
}
