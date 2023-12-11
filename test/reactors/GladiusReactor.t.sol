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

import {console} from "forge-std/console.sol";

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
        r.initialize(permit2, PROTOCOL_FEE_OWNER);

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

    //-------------------------- PARTIAL FILL TESTS --------------------------

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
        fillContract.execute(generateSignedOrder(order), quant);

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

    //-------------------------- HERLPERS --------------------------

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

    //============================ ORDERS ============================

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

    //============================ HELEPRS ============================

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
	console.log(order.fillThreshold);
	
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
}
