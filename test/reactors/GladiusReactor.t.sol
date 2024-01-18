// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {ExclusiveDutchOrder, ResolvedOrder, DutchOutput, DutchInput, BaseReactor} from "../../src/reactors/ExclusiveDutchOrderReactor.sol";
import {OrderInfo, InputToken, SignedOrder, OutputToken} from "../../src/base/ReactorStructs.sol";
import {BaseGladiusReactorTest, BaseGladiusReactor} from "../base/BaseGladiusReactor.t.sol";
import {ExclusiveDutchOrderLib} from "../../src/lib/ExclusiveDutchOrderLib.sol";
import {PartialFillLib, GladiusOrder} from "../../src/lib/PartialFillLib.sol";
import {CurrencyLibrary, NATIVE} from "../../src/lib/CurrencyLibrary.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {GladiusReactor} from "../../src/reactors/GladiusReactor.sol";
import {MockGladiusFill} from "../util/mock/MockGladiusFill.sol";
import {ReactorEvents} from "../../src/base/ReactorEvents.sol";
import {DutchDecayLib} from "../../src/lib/DutchDecayLib.sol";
import {OrderInfoBuilder} from "../util/OrderInfoBuilder.sol";
import {PermitSignature} from "../util/PermitSignature.sol";
import {OutputsBuilder} from "../util/OutputsBuilder.sol";
import {DeployPermit2} from "../util/DeployPermit2.sol";
import {MockERC20} from "../util/mock/MockERC20.sol";
import {Test} from "forge-std/Test.sol";

contract GladiusReactorTest is
    PermitSignature,
    DeployPermit2,
    BaseGladiusReactorTest
{
    using ExclusiveDutchOrderLib for ExclusiveDutchOrder;
    using PartialFillLib for GladiusOrder;
    using DutchDecayLib for DutchOutput[];
    using FixedPointMathLib for uint256;
    using OrderInfoBuilder for OrderInfo;
    using DutchDecayLib for DutchInput;
    using PartialFillLib for uint256;

    // Additional trading accounts
    uint256 swapper2Pk = 0x1337a228b322c69d420e;
    address swapper2 = vm.addr(swapper2Pk);
    uint256 swapper3Pk = 0xeeeeeeeeeeeeeeeeeeee;
    address swapper3 = vm.addr(swapper3Pk);

    //------------ DEFAULT ORDER PARAMS
    //  ----------------------------
    // |  input.amount        | 100 |
    // |  outputs[0].amount   | 200 |
    // |  fillThreshold       |  50 | min. fill => 50 out of 100
    //  ----------------------------
    uint256 public inputAmount = 100e18;
    uint256 public outputAmount = 200e18;
    uint256 public fillThreshold = 50e17;

    //------------ DEFAULT FILL PARAMS
    // Take 90 out of 100 input^
    uint256 public quantity = 90e18;

    function name() public pure override returns (string memory) {
        return "GladiusOrder";
    }

    function createReactor() public override returns (BaseGladiusReactor) {
        BaseGladiusReactor r = new GladiusReactor();
        r.initialize(address(permit2), PROTOCOL_FEE_OWNER);

        return r;
    }

    /// @dev Create and sign 'GladiusOrder'
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

        GladiusOrder memory order = GladiusOrder({
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
            fillThreshold: 1
        });
        orderHash = order.hash();

        return (
            SignedOrder(
                abi.encode(order),
                signOrder(swapperPrivateKey, address(permit2), order)
            ),
            orderHash
        );
    }

    //-------------------------- MATCHING TESTS --------------------------

    /// @dev Match resting bid with aggressive ask, that crosses the spread.
    ///            ------------------------------
    ///           |         X/Y pair             |
    ///            ------------------------------
    ///  bid:$2   | (Y/X (sell 200)  (buy 100))  | ------------------------
    ///           |                              |                         |
    ///  ask:$1.5 | (X/Y (sell 1000) (buy 1500)) | <-- lower than bid => *match* them
    ///            ------------------------------
    function test_AskCrossesSpread() public {
        GladiusOrder memory ask = customAsk(1_000e18, 1_500e18);
        GladiusOrder memory bid = defaultBid();

        mintAndApproveTwoSides(ask.input.endAmount, bid.input.endAmount);
        (
            uint256 swapperBalanceIN_0,
            uint256 swapperBalanceOUT_0
        ) = saveBalances(address(swapper));
        (
            uint256 swapper2BalanceIN_0,
            uint256 swapper2BalanceOUT_0
        ) = saveBalances(address(swapper2));

        // Generate orders.
        SignedOrder[] memory orders = new SignedOrder[](2);
        orders[0] = generateSignedOrder(ask);
        orders[1] = generateSignedOrderWithPk(bid, swapper2Pk);

        uint256[] memory quantities = new uint256[](orders.length);
        /// @dev Accept only 100 X tokens from 'ask',
        ///      because that's what 'bid' only needs.
        quantities[0] = bid.outputs[0].endAmount;
        /// @dev Sell all 200 Y tokens from 'bid',
        ///      because that's the max. we can sell.
        quantities[1] = bid.input.endAmount;

        fillContract.executeBatch(orders, quantities);

        /// @dev Amount that goes to 'filler' to cover gas expenses.
        ///      (p0 - p1) * size_of_smaller_order
        uint256 expensesCoverage = ((((quantities[0] * 1e18) / quantities[1]) -
            (ask.input.endAmount / ask.outputs[0].endAmount)) * quantities[0]) /
            1e18;

        /// @dev After execution, bid was fully filled, while ask's
        ///      execution was similar to how IOC orders behave -
        ///      it was filled with, as much amount, as possible
        ///      and its remainders were cancelled.
        ///   ------------------------------
        ///  |         X/Y pair             |
        ///   ------------------------------
        ///  | (Y/X (sell 0)   (buy 0))     | <- fully filled
        ///  |                              |
        ///  | (X/Y (sell 900) (buy 1350))  | <- partially filled & cancelled.
        ///   ------------------------------
        //-------------------- SWAPPER (ASK) ASSERTIONS

        /// @dev 'swapper' has the remaining input amount on his balance.
        assertEq(tokenIn.balanceOf(swapper), 900e18);
        /// @dev 'swapper' spent input amount, that equals to
        ///      the bid's output.
        assertEq(
            (swapperBalanceIN_0 - tokenIn.balanceOf(swapper)),
            quantities[0]
        );
        /// @dev 'swapper' received an amount of output tokens,
        ///      that equals to (quantity[0] - expensesCoverage)
        assertEq(
            (tokenOut.balanceOf(swapper) - swapperBalanceOUT_0),
            quantities[1] - expensesCoverage
        );

        //-------------------- SWAPPER2 (BID) ASSERTIONS

        /// @dev 'swapper2' spent his whole balance.
        assertEq(tokenOut.balanceOf(swapper2), 0);
        /// @dev 'swapper2' spent the exact input amount of his order.
        assertEq(
            swapper2BalanceOUT_0 - tokenOut.balanceOf(swapper2),
            bid.input.endAmount
        );
        /// @dev 50 'Y' tokens goes straight to the 'filler'.
        assertEq(tokenOut.balanceOf(address(fillContract)), expensesCoverage);
        /// @dev 'swapper2' received the exact amount of input tokens,
        ///      that was requested in his bid.
        assertEq(
            tokenIn.balanceOf(swapper2) - swapper2BalanceIN_0,
            bid.outputs[0].endAmount
        );
    }

    /// @dev Partially fill 1 resting order (X/Y), with 2 aggressive ones (Y/X):
    ///       ------------------------------
    ///      |         X/Y pair             |
    ///       ------------------------------
    ///      | (X/Y (sell 1000) (buy 2000)) | <-----
    ///      |                              |       | match
    ///      | (Y/X (sell 200)  (buy 100))  | ------|
    ///      | (Y/X (sell 1000) (buy 500))  | ______|
    ///       ------------------------------
    function test_PartFill1RestingWith2Aggressive() public {
        // (X/Y (sell 1000) (buy 2000))
        GladiusOrder memory ask = customAsk(1_000e18, 2_000e18);
        // (Y/X (sell 200)  (buy 100))
        GladiusOrder memory bid0 = defaultBid();
        // (Y/X (sell 1000) (buy 500))
        GladiusOrder memory bid1 = customOrder(
            address(tokenOut),
            address(tokenIn),
            1_000e18,
            500e18,
            swapper3,
            1
        );

        // Mint && approve amts for all 3 orders.
        mintAndApproveTwoSides(ask.input.endAmount, bid0.input.endAmount);
        mintAndApprove(
            address(bid1.input.token),
            bid1.input.endAmount,
            address(swapper3)
        );

        (
            uint256 swapperBalanceIN_0,
            uint256 swapperBalanceOUT_0
        ) = saveBalances(address(swapper));
        (
            uint256 swapper2BalanceIN_0,
            uint256 swapper2BalanceOUT_0
        ) = saveBalances(address(swapper2));
        (
            uint256 swapper3BalanceIN_0,
            uint256 swapper3BalanceOUT_0
        ) = saveBalances(address(swapper3));

        // Generate aforementioned orders.
        SignedOrder[] memory orders = new SignedOrder[](3);
        orders[0] = generateSignedOrder(ask);
        orders[1] = generateSignedOrderWithPk(bid0, swapper2Pk);
        orders[2] = generateSignedOrderWithPk(bid1, swapper3Pk);

        uint256[] memory quantities = new uint256[](orders.length);
        /// @dev 'quantity' is a sum of buy amts of 2 bids.
        quantities[0] = bid0.outputs[0].endAmount + bid1.outputs[0].endAmount;
        /// @dev 'quantity' is amount, that 'bid0' sells.
        ///      * 'bid0' will be fully filled.
        quantities[1] = bid0.input.endAmount;
        /// @dev 'quantity' is amount, that 'bid1' sells.
        ///      * 'bid1' will be fully filled.
        quantities[2] = bid1.input.endAmount;

        /// @dev Trade 2 bids against 1 ask.
        fillContract.executeBatch(orders, quantities);

        /// @dev After execution, 2 bids were fully filled,
        ///      while 1 ask, was filled partially.
        ///       -----------------------------
        ///      |         X/Y pair            |
        ///       -----------------------------
        ///      | (X/Y (sell 400)  (buy 800)) | <--- cancelled(*) from the book
        ///      |                             |
        ///      | (Y/X (sell 0)    (buy 0))   | <---| Both orders were
        ///      | (Y/X (sell 0)    (buy 0))   | ____| fully filled.
        ///       -----------------------------
        /// * it's not really cancelled, but rather the
        ///   remaining amounts can't be executed anymore.
        //-------------------- SWAPPER ASSERTIONS

        /// @dev 'swapper' has the remaining input amount on his balance.
        assertEq(tokenIn.balanceOf(swapper), 400e18);
        /// @dev 'swapper' spent input amount, that equals to
        ///      a sum of output amounts of 2 bids.
        assertEq(
            (swapperBalanceIN_0 - tokenIn.balanceOf(swapper)),
            bid0.outputs[0].endAmount + bid1.outputs[0].endAmount
        );
        /// @dev 'swapper' received an amount of output tokens,
        ///      that equals to a sum of input amounts of 2 bids.
        assertEq(
            (tokenOut.balanceOf(swapper) - swapperBalanceOUT_0),
            bid0.input.endAmount + bid1.input.endAmount
        );

        //-------------------- SWAPPER_2 ASSERTIONS

        /// @dev 'swapper2' has received the exact output amount of his bid.
        assertEq(
            (tokenIn.balanceOf(swapper2) - swapper2BalanceIN_0),
            bid0.outputs[0].endAmount
        );
        /// @dev 'swapper2' spent the exact input amount of his bid.
        assertEq(
            (swapper2BalanceOUT_0 - tokenOut.balanceOf(swapper2)),
            bid0.input.endAmount
        );

        //-------------------- SWAPPER_3 ASSERTIONS

        /// @dev All the same assertions as for 'swapper2'
        assertEq(
            (tokenIn.balanceOf(swapper3) - swapper3BalanceIN_0),
            bid1.outputs[0].endAmount
        );
        assertEq(
            (swapper3BalanceOUT_0 - tokenOut.balanceOf(swapper3)),
            bid1.input.endAmount
        );
    }

    /// @dev Fully match ask and bid together:
    ///       ----------------------------
    ///      |         X/Y pair           |
    ///       ----------------------------
    ///      | (X/Y (sell 100) (buy 200)) | <-----
    ///      |                            |       | match
    ///      | (Y/X (sell 200) (buy 100)) | <-----
    ///       ----------------------------
    function test_ExactMatch() public {
        // (X/Y (sell 100) (buy 200))
        GladiusOrder memory ask = defaultAsk();
        // (Y/X (sell 200) (buy 100))
        GladiusOrder memory bid = defaultBid();

        // Mint respective amounts for both swappers.
        mintAndApproveTwoSides(inputAmount, outputAmount);

        (
            uint256 swapperBalanceIN_0,
            uint256 swapperBalanceOUT_0
        ) = saveBalances(swapper);
        (
            uint256 swapper2BalanceIN_0,
            uint256 swapper2BalanceOUT_0
        ) = saveBalances(swapper2);

        SignedOrder[] memory orders = new SignedOrder[](2);
        orders[0] = generateSignedOrder(ask);
        orders[1] = generateSignedOrderWithPk(bid, swapper2Pk);

        /// @dev Fully take both orders.
        uint256[] memory quantities = new uint256[](orders.length);
        quantities[0] = ask.input.endAmount;
        quantities[1] = bid.input.endAmount;

        fillContract.executeBatch(orders, quantities);

        /// @dev After execution, both orders are fully filled.
        ///       ------------------------
        ///      |         X/Y pair       |
        ///       ------------------------
        ///      | (X/Y (sell 0) (buy 0)) | <---
        ///      |                        |     | fully executed
        ///      | (Y/X (sell 0) (buy 0)) | <---
        ///       ------------------------
        //-------------------- SWAPPER ASSERTIONS

        /// @dev Fot both swappers we assert, that they spent and received
        ///      the exact amounts from their orders.
        assertEq(
            (swapperBalanceIN_0 - tokenIn.balanceOf(swapper)),
            inputAmount
        );
        assertEq(
            (tokenOut.balanceOf(swapper) - swapperBalanceOUT_0),
            outputAmount
        );

        //-------------------- SWAPPER_2 ASSERTIONS
        assertEq(
            (swapper2BalanceOUT_0 - tokenOut.balanceOf(swapper2)),
            outputAmount
        );
        assertEq(
            (tokenIn.balanceOf(swapper2) - swapper2BalanceIN_0),
            inputAmount
        );
    }

    /// @dev Fuzz version of 'test_AskCrossesSpread'.
    ///      * We have 1 aggressive order (a) and 1 resting order (r)
    ///        as an input (their params).
    ///      * Aggressive order is "ask", while resting is "bid".
    ///          ------------------------
    ///         |         X/Y pair       |
    ///          ------------------------
    ///  bid:$n | (Y/X (sell a) (buy b)) | ------------------------
    ///         |                        |                         |
    ///  ask:$k | (X/Y (sell c) (buy d)) | <-- lower than bid => *match* them
    ///          ------------------------
    function testFuzz_OrderCrossesSpread(
        uint256 aggrInput,
        uint256 aggrOutput,
        uint256 restInput,
        uint256 restOutput
    ) public {
        /// @dev Set in/out amounts boundaries.
        restOutput = bound(restOutput, 1e5, type(uint120).max);
        restInput = bound(restInput, restOutput + 1, type(uint128).max);

        // In order to match (a) with (r), price(r) > price(a),
        // It won't be equal, since we need to keep some amount
        // to cover ~potential gas expenses.
        // So, we bound (a)o to be equal to (r)i
        // and (a)i to be greater than (r)i
        // so price(r) > price(a)
        aggrOutput = restInput;
        aggrInput = bound(aggrInput, aggrOutput + 1, type(uint136).max);

        assertGt(
            restInput.divWadUp(restOutput),
            aggrOutput.divWadUp(aggrInput)
        );
        GladiusOrder memory ask = customAsk(aggrInput, aggrOutput);
        GladiusOrder memory bid = customBid(restInput, restOutput);

        mintAndApproveTwoSides(aggrInput, restInput);
        (
            uint256 swapperBalanceIN_0,
            uint256 swapperBalanceOUT_0
        ) = saveBalances(address(swapper));
        (
            uint256 swapper2BalanceIN_0,
            uint256 swapper2BalanceOUT_0
        ) = saveBalances(address(swapper2));

        // Generate orders.
        SignedOrder[] memory orders = new SignedOrder[](2);
        orders[0] = generateSignedOrder(ask);
        orders[1] = generateSignedOrderWithPk(bid, swapper2Pk);

        uint256[] memory quantities = new uint256[](orders.length);
        /// @dev 'quantity' to take from aggressive ask.
        quantities[0] = min(ask.input.endAmount, bid.outputs[0].endAmount);
        quantities[1] = min(bid.input.endAmount, ask.outputs[0].endAmount);

        fillContract.executeBatch(orders, quantities);

        /// @dev Assume that updated balance of 'fillContract' is what covers expenses.
        uint256 expensesCoverage = tokenOut.balanceOf(address(fillContract));

        //-------------------- SWAPPER (ASK) ASSERTIONS

        assertEq(
            (swapperBalanceIN_0 - tokenIn.balanceOf(swapper)),
            quantities[0]
        );
        assertEq(
            (tokenOut.balanceOf(swapper) - swapperBalanceOUT_0),
            quantities[1] - expensesCoverage
        );

        //-------------------- SWAPPER2 (BID) ASSERTIONS

        assertEq(
            swapper2BalanceOUT_0 - tokenOut.balanceOf(swapper2),
            quantities[1]
        );
        assertEq(
            tokenIn.balanceOf(swapper2) - swapper2BalanceIN_0,
            quantities[0]
        );
    }

    //-------------------------- PARTIAL FILL TESTS --------------------------

    /// @dev Partially fill 1 order.
    function test_ExecutePartialFill() public {
        GladiusOrder memory order = defaultAsk();

        (
            InputToken memory inPf,
            OutputToken[] memory outPf
        ) = applyDecayAndPartition(order, quantity);

        mintAndApprove(
            address(tokenIn),
            order.input.endAmount,
            address(swapper)
        );
        tokenOut.mint(address(fillContract), outPf[0].amount);
        tokenOut.forceApprove(
            address(fillContract),
            address(reactor),
            outPf[0].amount
        );

        (
            uint256 swapperBalanceIN_0,
            uint256 swapperBalanceOUT_0
        ) = saveBalances(address(swapper));
        (uint256 fillerBalanceIN_0, uint256 fillerBalanceOUT_0) = saveBalances(
            address(fillContract)
        );

        /// @dev Partially fill the default order:
        ///       ---------                       ---------
        ///      | sell    |                     |         |
        ///      | 100     |                     |~~~~~~~~~|
        ///      |         |                     | sold    | <- buy 90 out of 100
        ///      |         |                     | 90      |
        ///      |=========| ---PARTIAL FILL---> |=========|
        ///      | buy     |                     |         |
        ///      | 200     |                     |~~~~~~~~~|
        ///      |         |                     | bought  | <- thus, amount to spend
        ///      |         |                     | 180     |    for filler is 180
        ///       ---------                       ---------
        fillContract.execute(generateSignedOrder(order), quantity);

        //-------------------- SWAPPER ASSERTIONS

        /// @dev 'swapper' spent only 90 input tokens.
        assertEq(
            (swapperBalanceIN_0 - tokenIn.balanceOf(swapper)),
            inPf.amount
        );
        /// @dev 'swapper' bought only 180 output tokens.
        assertEq(
            (tokenOut.balanceOf(swapper) - swapperBalanceOUT_0),
            outPf[0].amount
        );

        //-------------------- FILLER ASSERTIONS

        /// @dev 'filler' bought 90 input tokens
        assertEq(
            (tokenIn.balanceOf(address(fillContract)) - fillerBalanceIN_0),
            inPf.amount
        );
        /// @dev 'filler' spent 180 output tokens
        assertEq(
            (fillerBalanceOUT_0 - tokenOut.balanceOf(address(fillContract))),
            outPf[0].amount
        );
    }

    /// @dev Fuzz version of 'test_ExecutePartialFill'.
    function testFuzz_ExecutePartialFill(
        uint256 inAmt,
        uint256 outAmt,
        uint256 quant,
        uint256 threshold
    ) public {
        inAmt = bound(inAmt, 1e4, type(uint128).max);
        outAmt = bound(outAmt, 1e4, type(uint128).max);
        threshold = bound(threshold, 1e3, inAmt);
        quant = bound(quant, threshold, inAmt);

        GladiusOrder memory order = customOrder(
            address(tokenIn),
            address(tokenOut),
            inAmt,
            outAmt,
            address(swapper),
            threshold
        );

        (
            InputToken memory inPf,
            OutputToken[] memory outPf
        ) = applyDecayAndPartition(order, quant);

        mintAndApprove(
            address(tokenIn),
            order.input.endAmount,
            address(swapper)
        );
        tokenOut.mint(address(fillContract), outPf[0].amount);
        tokenOut.forceApprove(
            address(fillContract),
            address(reactor),
            outPf[0].amount
        );

        (
            uint256 swapperBalanceIN_0,
            uint256 swapperBalanceOUT_0
        ) = saveBalances(address(swapper));
        (uint256 fillerBalanceIN_0, uint256 fillerBalanceOUT_0) = saveBalances(
            address(fillContract)
        );

        fillContract.execute(generateSignedOrder(order), quant);

        //-------------------- SWAPPER ASSERTIONS

        assertEq(
            (swapperBalanceIN_0 - tokenIn.balanceOf(swapper)),
            inPf.amount
        );
        assertEq(
            (tokenOut.balanceOf(swapper) - swapperBalanceOUT_0),
            outPf[0].amount
        );

        //-------------------- FILLER ASSERTIONS

        assertEq(
            (tokenIn.balanceOf(address(fillContract)) - fillerBalanceIN_0),
            inPf.amount
        );
        assertEq(
            (fillerBalanceOUT_0 - tokenOut.balanceOf(address(fillContract))),
            outPf[0].amount
        );
    }

    //-------------------------- ORDERS --------------------------

    function generateSignedOrder(
        GladiusOrder memory order
    ) private view returns (SignedOrder memory result) {
        bytes memory sig = signOrder(
            swapperPrivateKey,
            address(permit2),
            order
        );
        result = SignedOrder(abi.encode(order), sig);
    }

    function generateSignedOrderWithPk(
        GladiusOrder memory order,
        uint256 privateKey
    ) internal view returns (SignedOrder memory result) {
        bytes memory sig = signOrder(privateKey, address(permit2), order);
        result = SignedOrder(abi.encode(order), sig);
    }

    function defaultAsk() internal view returns (GladiusOrder memory) {
        return customAsk(inputAmount, outputAmount);
    }

    function defaultBid() internal view returns (GladiusOrder memory order) {
        return customBid(outputAmount, inputAmount);
    }

    function customAsk(
        uint256 i,
        uint256 o
    ) internal view returns (GladiusOrder memory order) {
        return
            customOrder(address(tokenIn), address(tokenOut), i, o, swapper, 1);
    }

    function customBid(
        uint256 i,
        uint256 o
    ) internal view returns (GladiusOrder memory order) {
        return
            customOrder(address(tokenOut), address(tokenIn), i, o, swapper2, 1);
    }

    /// @param inputT - input token
    /// @param outputT - output token
    /// @param i - input amount
    /// @param o - output amount
    /// @param who - swapper address
    /// @param ft - fillThreshold
    function customOrder(
        address inputT,
        address outputT,
        uint256 i,
        uint256 o,
        address who,
        uint256 ft
    ) internal view returns (GladiusOrder memory order) {
        order = GladiusOrder({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(who)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 300,
            input: DutchInput(MockERC20(inputT), i, i),
            outputs: OutputsBuilder.singleDutch(outputT, o, o, who),
            fillThreshold: ft
        });
    }

    //-------------------------- HELPERS --------------------------

    /// @dev Mint tokens for both swappers, and approve amounts to 'permit2'.
    function mintAndApproveTwoSides(uint256 amt0, uint256 amt1) internal {
        mintAndApprove(address(tokenIn), amt0, address(swapper));
        mintAndApprove(address(tokenOut), amt1, address(swapper2));
    }

    function mintAndApprove(address token, uint256 amt, address who) internal {
        MockERC20(token).mint(who, amt);
        MockERC20(token).forceApprove(who, address(permit2), amt);
    }

    function saveBalances(
        address dude
    ) internal view returns (uint256 inBalance, uint256 outBalance) {
        inBalance = tokenIn.balanceOf(dude);
        outBalance = tokenOut.balanceOf(dude);
    }

    /// @dev Validates if partition was correctly applied.
    /// @return i - 'InputToken' struct after applied decay and partition.
    /// @return o - 'OutputToken' struct after applied decay and partition.
    function applyDecayAndPartition(
        GladiusOrder memory order,
        uint256 quant
    ) internal returns (InputToken memory, OutputToken[] memory) {

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
        (InputToken memory inPf, OutputToken[] memory outPf) = quant
            .applyPartition(input, outputs, order.fillThreshold);

        uint256 initialExchangeRate = (
            input.amount.divWadUp(outputs[0].amount)
        );
        uint256 newExchangeRate = inPf.amount.divWadUp(outPf[0].amount);
        /// @dev Verify, that the exchange rate is the same after partition.
        assertEq(initialExchangeRate, newExchangeRate);

        return (inPf, outPf);
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // in case of equality return the 1st number.
        z = x <= y ? x : y;
    }
}
