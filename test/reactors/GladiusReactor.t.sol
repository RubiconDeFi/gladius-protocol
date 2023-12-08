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
    // |  fillThreshold       |  25 | min. fill => 25 out of 200
    //  ----------------------------
    uint256 public inputAmount = 100e18;
    uint256 public outputAmount = 200e18;
    uint256 public fillThreshold = 25e17;

    //------------ DEFAULT FILL PARAMS
    // Take 90 out of 100 input^
    uint256 public quantity = 90e18;

    function name() public pure override returns (string memory) {
        return "ExclusiveDutchOrderWithPF";
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
    /*function mintAndApproveTwoSides(uint256 amt0, uint256 amt1) internal {
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
        GladiusOrder memory order
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
        (InputToken memory inPf, OutputToken[] memory outPf) = quantity
            .applyPartition(input, outputs, fillThreshold);

        uint256 initialExchangeRate = (
            input.amount.divWadUp(outputs[0].amount)
        );
        uint256 newExchangeRate = inPf.amount.divWadUp(outPf[0].amount);
        /// @dev Verify, that the exchange rate is the same after partition.
        assertEq(initialExchangeRate, newExchangeRate);

        return (inPf, outPf);
    }*/
}
