// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {RubiconExecutor} from "../../src/rubicon/RubiconExecutor.sol";
import {DutchOrderReactor, DutchOrder, DutchInput, DutchOutput} from "../../src/reactors/DutchOrderReactor.sol";
import {MockERC20} from "../util/mock/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {MockRubiconMarket} from "../util/mock/MockRubiconMarket.sol";
import {OutputToken, InputToken, OrderInfo, ResolvedOrder, SignedOrder} from "../../src/base/ReactorStructs.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {DeployPermit2} from "../util/DeployPermit2.sol";
import {OrderInfoBuilder} from "../util/OrderInfoBuilder.sol";
import {OutputsBuilder} from "../util/OutputsBuilder.sol";
import {PermitSignature} from "../util/PermitSignature.sol";

// This set of tests will use a mock swap router to simulate the Uniswap swap router.
contract RubiconExecutorTest is
    Test,
    PermitSignature,
    GasSnapshot,
    DeployPermit2
{
    using OrderInfoBuilder for OrderInfo;

    // PKs
    uint256 fillerPrivateKey;
    uint256 swapperPrivateKey;
    uint256 feeToPrivateKey;

    // Tokens
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    WETH weth;

    // Roles
    address filler;
    address swapper;
    address feeTo;

    // Contracts
    RubiconExecutor rubiExecutor;
    MockRubiconMarket market;
    DutchOrderReactor reactor;
    IPermit2 permit2;

    uint256 constant ONE = 10 ** 18;
    // Represents a 0.3% fee, but setting this doesn't matter
    uint24 constant FEE = 3000;
    address constant PROTOCOL_FEE_OWNER = address(80085);

    // Offer IDs
    uint256 bid;
    uint256 ask;

    // Constant values for offers.
    uint256 constant pay_amt_in = 100_000e18;
    uint256 constant buy_amt_in = 500_000e18;
    uint256 constant pay_amt_out = 190_000e18;
    uint256 constant buy_amt_out = 200_000e18;

    // Order data:
    uint256 constant inputAmount = 50_000e18;
    uint256 public outputAmount;

    // to test sweeping ETH
    receive() external payable {}

    function setUp() public {
        vm.warp(1000);

        // Mock input/output tokens
        tokenIn = new MockERC20("Input", "IN", 18);
        tokenOut = new MockERC20("Output", "OUT", 18);
        weth = new WETH();

        tokenOut.mint(address(this), pay_amt_out * 10000);
        tokenIn.mint(address(this), pay_amt_in * 10000);

        // Mock filler and swapper
        fillerPrivateKey = 0x12341234;
        filler = vm.addr(fillerPrivateKey);
        swapperPrivateKey = 0x12341235;
        swapper = vm.addr(swapperPrivateKey);
        feeToPrivateKey = 0x12341236;
        feeTo = vm.addr(feeToPrivateKey);

        // Instantiate relevant contracts
        market = new MockRubiconMarket();

        market.initialize(feeTo);
        market.setFeeBPS(20);
        market.setMakerFee(38);

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

        permit2 = IPermit2(deployPermit2());
        reactor = new DutchOrderReactor(permit2, PROTOCOL_FEE_OWNER);
        rubiExecutor = new RubiconExecutor(
            address(this),
            address(market),
            address(reactor),
            address(rubiExecutor)
        );

        /// @dev Don't need to account for the fee here.
        ///      Because, it's on top.
        outputAmount = market.getBuyAmount(
            IERC20(address(tokenOut)),
            IERC20(address(tokenIn)),
            inputAmount
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

        (, uint256 approveAmount) = market.getPayAmountWithFee(
            IERC20(address(tokenIn)),
            IERC20(address(tokenOut)),
            outputAmount
        );

        /// @dev The EXACT amount we need to execute trade + 10 wei rounding...
        tokenIn.mint(address(rubiExecutor), approveAmount + 10);

        vm.prank(address(reactor));
        rubiExecutor.reactorCallback(resolvedOrders, "0x");

        assertEq(tokenOut.balanceOf(address(rubiExecutor)), outputAmount);
        assertEq(tokenOut.balanceOf(address(swapper)), 0);

        assertEq(
            tokenOut.allowance(address(rubiExecutor), address(reactor)),
            type(uint256).max
        );
    }

    /*

    // Output will resolve to 0.5. Input = 1. SwapRouter exchanges at 1 to 1 rate.
    // There will be 0.5 output token remaining in SwapRouter02Executor.
    function testExecute() public {
        DutchOrder memory order = DutchOrder({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp - 100,
            decayEndTime: block.timestamp + 100,
            input: DutchInput(tokenIn, ONE, ONE),
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                ONE,
                0,
                address(swapper)
            )
        });

        tokenIn.mint(swapper, ONE);
        tokenOut.mint(address(mockSwapRouter), ONE);

        address[] memory tokensToApproveForSwapRouter02 = new address[](1);
        tokensToApproveForSwapRouter02[0] = address(tokenIn);

        address[] memory tokensToApproveForReactor = new address[](1);
        tokensToApproveForReactor[0] = address(tokenOut);

        bytes[] memory multicallData = new bytes[](1);
        ExactInputParams memory exactInputParams = ExactInputParams({
            path: abi.encodePacked(tokenIn, FEE, tokenOut),
            recipient: address(swapRouter02Executor),
            amountIn: ONE,
            amountOutMinimum: 0
        });
        multicallData[0] = abi.encodeWithSelector(
            ISwapRouter02.exactInput.selector,
            exactInputParams
        );

        snapStart("SwapRouter02ExecutorExecute");
        swapRouter02Executor.execute(
            SignedOrder(
                abi.encode(order),
                signOrder(swapperPrivateKey, address(permit2), order)
            ),
            abi.encode(
                tokensToApproveForSwapRouter02,
                tokensToApproveForReactor,
                multicallData
            )
        );
        snapEnd();

        assertEq(tokenIn.balanceOf(swapper), 0);
        assertEq(tokenIn.balanceOf(address(swapRouter02Executor)), 0);
        assertEq(tokenOut.balanceOf(swapper), ONE / 2);
        assertEq(tokenOut.balanceOf(address(swapRouter02Executor)), ONE / 2);
    }

    function testExecuteAlreadyApproved() public {
        DutchOrder memory order = DutchOrder({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp - 100,
            decayEndTime: block.timestamp + 100,
            input: DutchInput(tokenIn, ONE, ONE),
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                ONE,
                0,
                address(swapper)
            )
        });

        tokenIn.mint(swapper, 2 * ONE);
        tokenOut.mint(address(mockSwapRouter), 2 * ONE);

        address[] memory tokensToApproveForSwapRouter02 = new address[](1);
        tokensToApproveForSwapRouter02[0] = address(tokenIn);

        address[] memory tokensToApproveForReactor = new address[](1);
        tokensToApproveForReactor[0] = address(tokenOut);

        bytes[] memory multicallData = new bytes[](1);
        ExactInputParams memory exactInputParams = ExactInputParams({
            path: abi.encodePacked(tokenIn, FEE, tokenOut),
            recipient: address(swapRouter02Executor),
            amountIn: ONE,
            amountOutMinimum: 0
        });
        multicallData[0] = abi.encodeWithSelector(
            ISwapRouter02.exactInput.selector,
            exactInputParams
        );

        swapRouter02Executor.execute(
            SignedOrder(
                abi.encode(order),
                signOrder(swapperPrivateKey, address(permit2), order)
            ),
            abi.encode(
                tokensToApproveForSwapRouter02,
                tokensToApproveForReactor,
                multicallData
            )
        );

        DutchOrder memory order2 = DutchOrder({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100)
                .withNonce(1234),
            decayStartTime: block.timestamp - 100,
            decayEndTime: block.timestamp + 100,
            input: DutchInput(tokenIn, ONE, ONE),
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                ONE,
                0,
                address(swapper)
            )
        });

        tokensToApproveForSwapRouter02 = new address[](0);
        tokensToApproveForReactor = new address[](0);

        snapStart("SwapRouter02ExecutorExecuteAlreadyApproved");
        swapRouter02Executor.execute(
            SignedOrder(
                abi.encode(order2),
                signOrder(swapperPrivateKey, address(permit2), order2)
            ),
            abi.encode(
                tokensToApproveForSwapRouter02,
                tokensToApproveForReactor,
                multicallData
            )
        );
        snapEnd();

        assertEq(tokenIn.balanceOf(swapper), 0);
        assertEq(tokenIn.balanceOf(address(swapRouter02Executor)), 0);
        assertEq(tokenOut.balanceOf(swapper), ONE);
        assertEq(tokenOut.balanceOf(address(swapRouter02Executor)), ONE);
    }

    // Requested output = 2 & input = 1. SwapRouter swaps at 1 to 1 rate, so there will
    // there will be an overflow error when reactor tries to transfer 2 outputToken out of fill contract.
    function testExecuteInsufficientOutput() public {
        DutchOrder memory order = DutchOrder({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp - 100,
            decayEndTime: block.timestamp + 100,
            input: DutchInput(tokenIn, ONE, ONE),
            // The output will resolve to 2
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                ONE * 2,
                ONE * 2,
                address(swapper)
            )
        });

        tokenIn.mint(swapper, ONE);
        tokenOut.mint(address(mockSwapRouter), ONE * 2);

        address[] memory tokensToApproveForSwapRouter02 = new address[](1);
        tokensToApproveForSwapRouter02[0] = address(tokenIn);

        address[] memory tokensToApproveForReactor = new address[](1);
        tokensToApproveForReactor[0] = address(tokenOut);

        bytes[] memory multicallData = new bytes[](1);
        ExactInputParams memory exactInputParams = ExactInputParams({
            path: abi.encodePacked(tokenIn, FEE, tokenOut),
            recipient: address(swapRouter02Executor),
            amountIn: ONE,
            amountOutMinimum: 0
        });
        multicallData[0] = abi.encodeWithSelector(
            ISwapRouter02.exactInput.selector,
            exactInputParams
        );

        vm.expectRevert("TRANSFER_FROM_FAILED");
        swapRouter02Executor.execute(
            SignedOrder(
                abi.encode(order),
                signOrder(swapperPrivateKey, address(permit2), order)
            ),
            abi.encode(
                tokensToApproveForSwapRouter02,
                tokensToApproveForReactor,
                multicallData
            )
        );
    }

    // Two orders, first one has input = 1 and outputs = [1]. Second one has input = 3
    // and outputs = [2]. Mint swapper 10 input and mint mockSwapRouter 10 output. After
    // the execution, swapper should have 6 input / 3 output, mockSwapRouter should have
    // 4 input / 6 output, and swapRouter02Executor should have 0 input / 1 output.
    function testExecuteBatch() public {
        uint256 inputAmount = 10 ** 18;
        uint256 outputAmount = inputAmount;

        tokenIn.mint(address(swapper), inputAmount * 10);
        tokenOut.mint(address(mockSwapRouter), outputAmount * 10);
        tokenIn.forceApprove(swapper, address(permit2), type(uint256).max);

        SignedOrder[] memory signedOrders = new SignedOrder[](2);
        DutchOrder memory order1 = DutchOrder({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            input: DutchInput(tokenIn, inputAmount, inputAmount),
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                outputAmount,
                outputAmount,
                swapper
            )
        });
        bytes memory sig1 = signOrder(
            swapperPrivateKey,
            address(permit2),
            order1
        );
        signedOrders[0] = SignedOrder(abi.encode(order1), sig1);

        DutchOrder memory order2 = DutchOrder({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100)
                .withNonce(1),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            input: DutchInput(tokenIn, inputAmount * 3, inputAmount * 3),
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                outputAmount * 2,
                outputAmount * 2,
                swapper
            )
        });
        bytes memory sig2 = signOrder(
            swapperPrivateKey,
            address(permit2),
            order2
        );
        signedOrders[1] = SignedOrder(abi.encode(order2), sig2);

        address[] memory tokensToApproveForSwapRouter02 = new address[](1);
        tokensToApproveForSwapRouter02[0] = address(tokenIn);

        address[] memory tokensToApproveForReactor = new address[](1);
        tokensToApproveForReactor[0] = address(tokenOut);

        bytes[] memory multicallData = new bytes[](1);
        ExactInputParams memory exactInputParams = ExactInputParams({
            path: abi.encodePacked(tokenIn, FEE, tokenOut),
            recipient: address(swapRouter02Executor),
            amountIn: inputAmount * 4,
            amountOutMinimum: 0
        });
        multicallData[0] = abi.encodeWithSelector(
            ISwapRouter02.exactInput.selector,
            exactInputParams
        );

        swapRouter02Executor.executeBatch(
            signedOrders,
            abi.encode(
                tokensToApproveForSwapRouter02,
                tokensToApproveForReactor,
                multicallData
            )
        );
        assertEq(tokenOut.balanceOf(swapper), 3 ether);
        assertEq(tokenIn.balanceOf(swapper), 6 ether);
        assertEq(tokenOut.balanceOf(address(mockSwapRouter)), 6 ether);
        assertEq(tokenIn.balanceOf(address(mockSwapRouter)), 4 ether);
        assertEq(tokenOut.balanceOf(address(swapRouter02Executor)), 10 ** 18);
        assertEq(tokenIn.balanceOf(address(swapRouter02Executor)), 0);
    }

    function testNotWhitelistedCaller() public {
        DutchOrder memory order = DutchOrder({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp - 100,
            decayEndTime: block.timestamp + 100,
            input: DutchInput(tokenIn, ONE, ONE),
            outputs: OutputsBuilder.singleDutch(
                address(tokenOut),
                ONE,
                0,
                address(swapper)
            )
        });

        tokenIn.mint(swapper, ONE);
        tokenOut.mint(address(mockSwapRouter), ONE);

        address[] memory tokensToApproveForSwapRouter02 = new address[](1);
        tokensToApproveForSwapRouter02[0] = address(tokenIn);

        bytes[] memory multicallData = new bytes[](1);
        ExactInputParams memory exactInputParams = ExactInputParams({
            path: abi.encodePacked(tokenIn, FEE, tokenOut),
            recipient: address(swapRouter02Executor),
            amountIn: ONE,
            amountOutMinimum: 0
        });
        multicallData[0] = abi.encodeWithSelector(
            ISwapRouter02.exactInput.selector,
            exactInputParams
        );

        vm.prank(address(0xbeef));
        vm.expectRevert(SwapRouter02Executor.CallerNotWhitelisted.selector);
        swapRouter02Executor.execute(
            SignedOrder(
                abi.encode(order),
                signOrder(swapperPrivateKey, address(permit2), order)
            ),
            abi.encode(tokensToApproveForSwapRouter02, multicallData)
        );
    }

    // Very similar to `testReactorCallback`, but do not vm.prank the reactor when calling `reactorCallback`, so reverts
    function testMsgSenderNotReactor() public {
        OutputToken[] memory outputs = new OutputToken[](1);
        outputs[0].token = address(tokenOut);
        outputs[0].amount = ONE;
        address[] memory tokensToApproveForSwapRouter02 = new address[](1);
        tokensToApproveForSwapRouter02[0] = address(tokenIn);

        bytes[] memory multicallData = new bytes[](1);
        ExactInputParams memory exactInputParams = ExactInputParams({
            path: abi.encodePacked(tokenIn, FEE, tokenOut),
            recipient: address(swapRouter02Executor),
            amountIn: ONE,
            amountOutMinimum: 0
        });
        multicallData[0] = abi.encodeWithSelector(
            ISwapRouter02.exactInput.selector,
            exactInputParams
        );
        bytes memory callbackData = abi.encode(
            tokensToApproveForSwapRouter02,
            multicallData
        );

        ResolvedOrder[] memory resolvedOrders = new ResolvedOrder[](1);
        bytes memory sig = hex"1234";
        resolvedOrders[0] = ResolvedOrder(
            OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            InputToken(tokenIn, ONE, ONE),
            outputs,
            sig,
            keccak256(abi.encode(1))
        );
        tokenIn.mint(address(swapRouter02Executor), ONE);
        tokenOut.mint(address(mockSwapRouter), ONE);
        vm.expectRevert(SwapRouter02Executor.MsgSenderNotReactor.selector);
        swapRouter02Executor.reactorCallback(resolvedOrders, callbackData);
    }

    function testUnwrapWETH() public {
        vm.deal(address(weth), 1 ether);
        deal(address(weth), address(swapRouter02Executor), ONE);
        uint256 balanceBefore = address(this).balance;
        swapRouter02Executor.unwrapWETH(address(this));
        uint256 balanceAfter = address(this).balance;
        assertEq(balanceAfter - balanceBefore, 1 ether);
    }

    function testUnwrapWETHNotOwner() public {
        vm.expectRevert("UNAUTHORIZED");
        vm.prank(address(0xbeef));
        swapRouter02Executor.unwrapWETH(address(this));
    }

    function testWithdrawETH() public {
        vm.deal(address(swapRouter02Executor), 1 ether);
        uint256 balanceBefore = address(this).balance;
        swapRouter02Executor.withdrawETH(address(this));
        uint256 balanceAfter = address(this).balance;
        assertEq(balanceAfter - balanceBefore, 1 ether);
    }

    function testWithdrawETHNotOwner() public {
        vm.expectRevert("UNAUTHORIZED");
        vm.prank(address(0xbeef));
        swapRouter02Executor.withdrawETH(address(this));
    }*/
}
