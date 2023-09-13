// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {ResolvedOrder, OutputToken, SignedOrder} from "../base/ReactorStructs.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IReactorCallback} from "../interfaces/IReactorCallback.sol";
import {IRubiconMarket} from "../interfaces/IRubiconMarket.sol";
import {IReactor} from "../interfaces/IReactor.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

import {console} from "forge-std/console.sol";

/// @notice A 'Filler' contract, that uses Rubicon's
///         on-chain liquidity to execute trades.
contract RubiconExecutor is IReactorCallback, Owned {
    /// @dev Custom errors.
    error InsufficientInputAmount();
    error CallerNotWhitelisted();
    error MsgSenderNotReactor();
    error IncorrectOutLength();

    address private immutable whitelistedCaller;
    IReactor private immutable reactor;
    IRubiconMarket private immutable market;

    /// @dev Access-control modifiers.
    modifier onlyWhitelistedCaller() {
        if (msg.sender != whitelistedCaller) revert CallerNotWhitelisted();
        _;
    }

    modifier onlyReactor() {
        if (msg.sender != address(reactor)) revert MsgSenderNotReactor();
        _;
    }

    constructor(
        address _whitelistedCaller,
        address _market,
        address _reactor,
        address _owner
    ) Owned(_owner) {
        whitelistedCaller = _whitelistedCaller;
        market = IRubiconMarket(_market);
        reactor = IReactor(_reactor);
    }

    //============================= EXECUTION =============================

    /// @dev Entry-point, used to trade orders, against on-chain
    ///      liquidity in 'RubiconMarket'.
    function execute(
        SignedOrder calldata order
    ) external onlyWhitelistedCaller {
        reactor.executeWithCallback(order, "0x");
    }

    // TODO: add 'executeBatchWithCallback' to trade against off-chain liquidity.

    //============================= CALLBACK =============================

    // TODO: adapt this function for both off-chain and on-chain liq.
    /// @dev Only on-chain path rn!
    function reactorCallback(
        ResolvedOrder[] calldata orders,
        bytes calldata callbackData
    ) external onlyReactor {
        _matchWithOnChainLiquidity(orders[0]);
    }

    //============================= INTERNALS =============================

    /// @dev Input tokens already transferred here by Reactor.
    /// @dev Trade input tokens against on-chain liquidity in the 'RubiconMarket'.
    /// @dev Permit2 contract MUST be approved with 'approve_amount'!
    function _matchWithOnChainLiquidity(ResolvedOrder memory _order) internal {
        // TODO: take more than 1 out tokens.
        // TODO: thus, it's needed to divide input amount to get multiple
        // output tokens (should be done off-chain).
        if (_order.outputs.length > 1) revert IncorrectOutLength();

        IERC20 _input = IERC20(address(_order.input.token));
        IERC20 _output = IERC20(address(_order.outputs[0].token));
        /// @dev Input amount should include fee to pay
        ///      at 'sellAllAmount' step.
        uint256 _inputAmount = _order.input.amount;
        uint256 _outputAmount = _order.outputs[0].amount;

        console.log("I balance:", _input.balanceOf(address(this)));

        _inputInfiniteApproval(_input, _inputAmount);

        /// @dev We don't verify the output, because it will be
        ///      validated by the Reactor contract.
        market.sellAllAmount(_input, _inputAmount, _output, _outputAmount);

        _outputInfiniteApproval(_output, _outputAmount);
    }

    //============================= HELPERS =============================

    /// @dev Approve input tokens to 'RubiconMarket'.
    function _inputInfiniteApproval(IERC20 _input, uint256 _amount) internal {
        address _market = address(market);

        if (_input.allowance(address(this), _market) < _amount) {
            _input.approve(_market, type(uint256).max);
        }
    }

    /// @dev Approve output tokens to Reactor.
    function _outputInfiniteApproval(IERC20 _output, uint256 _amount) internal {
        address _reactor = address(reactor);

        if (_output.allowance(address(this), _reactor) < _amount) {
            _output.approve(_reactor, type(uint256).max);
        }
    }
}
