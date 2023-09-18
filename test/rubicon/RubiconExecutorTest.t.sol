// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {OutputToken, InputToken, OrderInfo, ResolvedOrder, SignedOrder} from "../../src/base/ReactorStructs.sol";
import {DutchOrderReactor, DutchOrder, DutchInput, DutchOutput} from "../../src/reactors/DutchOrderReactor.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ProcuratorBase} from "../../src/rubicon-executor/Procurator.sol";
import {Procurator} from "../../src/rubicon-executor/Procurator.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {MockRubiconMarket} from "../util/mock/MockRubiconMarket.sol";
import {OrderInfoBuilder} from "../util/OrderInfoBuilder.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {PermitSignature} from "../util/PermitSignature.sol";
import {OutputsBuilder} from "../util/OutputsBuilder.sol";
import {DeployPermit2} from "../util/DeployPermit2.sol";
import {MockERC20} from "../util/mock/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

contract RubiconExecutorTest is
    Test,
    PermitSignature,
    GasSnapshot,
    DeployPermit2
{
    using OrderInfoBuilder for OrderInfo;

    // Private keys
    uint256 fillerPrivateKey;
    uint256 swapperPrivateKey;

    // Tokens
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    // Roles
    address filler;
    address swapper;
    address feeTo = address(0xfee);

    // Contracts
    Procurator procurator;
    MockRubiconMarket market;
    DutchOrderReactor reactor;
    IPermit2 permit2;

    // Offer IDs
    uint256 bid;
    uint256 ask;

    // Constant values for offers.
    uint256 constant pay_amt_in = 100_000e18;
    uint256 constant buy_amt_in = 500_000e18;
    uint256 constant pay_amt_out = 190_000e18;
    uint256 constant buy_amt_out = 200_000e18;

    // Order data:
    uint256 public payAmount;
    uint256 public inputAmount;
    uint256 public outputAmount;

    function setUp() public {
        vm.warp(1000);

        // Mock input/output tokens
        tokenIn = new MockERC20("Input", "IN", 18);
        tokenOut = new MockERC20("Output", "OUT", 18);

        // Mock filler and swapper
        fillerPrivateKey = 0x12341234;
        filler = vm.addr(fillerPrivateKey);
        swapperPrivateKey = 0x12341235;
        swapper = vm.addr(swapperPrivateKey);

        // Instantiate relevant contracts
        permit2 = IPermit2(deployPermit2());
        reactor = new DutchOrderReactor(permit2, address(0));

        // Instantiate relevant contracts
        market = new MockRubiconMarket();

        market.initialize(feeTo);
        market.setFeeBPS(20);
        market.setMakerFee(38);

        tokenIn.mint(address(this), pay_amt_in * 10000);
        tokenOut.mint(address(this), pay_amt_out * 10000);

        tokenIn.approve(address(market), type(uint256).max);
        tokenOut.approve(address(market), type(uint256).max);

        /// @dev Add liquidity to both sides of the book
        bid = market.offer(
            pay_amt_in,
            IERC20(address(tokenIn)),
            buy_amt_out,
            IERC20(address(tokenOut))
        );
        ask = market.offer(
            pay_amt_out,
            IERC20(address(tokenOut)),
            buy_amt_in,
            IERC20(address(tokenIn))
        );

        procurator = new Procurator();
        procurator.initialize(address(this), address(market), address(reactor));

        /// @dev One third of 'pay_amt' of 'tokenOut'.
        outputAmount = 10_000e18;

        /// @dev Account for 'RubiconMarket' fees.
        (payAmount, inputAmount) = market.getPayAmountWithFee(
            IERC20(address(tokenIn)),
            IERC20(address(tokenOut)),
            outputAmount
        );

        // Do appropriate max approvals
        tokenIn.forceApprove(swapper, address(permit2), type(uint256).max);
    }

    function testReactorCallback() public {
        OutputToken[] memory outputs = new OutputToken[](1);
        outputs[0].token = address(tokenOut);
        outputs[0].amount = outputAmount;
        outputs[0].recipient = swapper;

        ResolvedOrder[] memory resolvedOrders = new ResolvedOrder[](1);

        bytes memory sig = hex"1234";
        resolvedOrders[0] = ResolvedOrder(
            OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            InputToken(tokenIn, inputAmount, inputAmount),
            outputs,
            sig,
            keccak256(abi.encode(1))
        );

        /// @dev The EXACT amount we need to execute trade + 10 wei rounding...
        tokenIn.mint(address(procurator), inputAmount);

        //--------- Off-chain match data
        /// @dev It will remain empty, because we don't need it here.
        ProcuratorBase.OffChainMatch[] memory offChainMatchData;

        //--------- On-chain match data
        ProcuratorBase.OnChainMatch memory onChainMatchData = ProcuratorBase
            .OnChainMatch({onChainProportion: 1e18, payAmt: payAmount});

        ProcuratorBase.Matching[]
            memory matchingData = new ProcuratorBase.Matching[](1);

        matchingData[0] = ProcuratorBase.Matching({
            /// @dev 100% of the order shall be traded
            ///      against on-chain liquidity.
            onChainMatch: onChainMatchData,
            offChainMatch: offChainMatchData
        });

        vm.prank(address(reactor));
        procurator.reactorCallback(resolvedOrders, abi.encode(matchingData));

        assertEq(tokenOut.balanceOf(address(procurator)), outputAmount);
        assertEq(tokenOut.balanceOf(address(swapper)), 0);

        assertEq(
            tokenOut.allowance(address(procurator), address(reactor)),
            type(uint256).max
        );
    }

    function testExecute() public {
        DutchOrder memory order = DutchOrder({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp - 100,
            decayEndTime: block.timestamp + 100,
            input: DutchInput(tokenIn, inputAmount, inputAmount),
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                outputAmount,
                outputAmount,
                address(swapper)
            )
        });

        tokenIn.mint(swapper, inputAmount);

        //--------- Off-chain match data
        /// @dev It will remain empty, because we don't need it here.
        ProcuratorBase.OffChainMatch[] memory offChainMatchData;

        //--------- On-chain match data
        ProcuratorBase.OnChainMatch memory onChainMatchData = ProcuratorBase
            .OnChainMatch({onChainProportion: 1e18, payAmt: payAmount});

        ProcuratorBase.Matching[]
            memory matchingData = new ProcuratorBase.Matching[](1);

        matchingData[0] = ProcuratorBase.Matching({
            /// @dev 100% of the order shall be traded
            ///      against on-chain liquidity.
            onChainMatch: onChainMatchData,
            offChainMatch: offChainMatchData
        });

        procurator.execute(
            SignedOrder(
                abi.encode(order),
                signOrder(swapperPrivateKey, address(permit2), order)
            ),
            abi.encode(matchingData)
        );

        assertEq(tokenIn.balanceOf(swapper), 0);
        assertEq(tokenIn.balanceOf(address(procurator)), 0);
        assertEq(tokenOut.balanceOf(swapper), outputAmount);
        assertEq(
            tokenOut.balanceOf(address(market)),
            pay_amt_out - outputAmount
        );
    }
}
