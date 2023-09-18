// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import "./ProcuratorBase.sol";

contract Procurator is ProcuratorBase {
    using FixedPointMathLib for uint256;

    //---------------------------- MAIN ----------------------------

    function execute(
        SignedOrder calldata order,
        bytes calldata callbackData
    ) external override onlyPermissioned {
        reactor.executeWithCallback(order, callbackData);
    }

    /// @dev Input amount in 'orders' MUST include amount to pay
    ///      fees in 'RubiconMarket'.
    function reactorCallback(
        ResolvedOrder[] calldata orders,
        bytes calldata callbackData
    ) external override onlyReactor {
        Matching[] memory matching = abi.decode(callbackData, (Matching[]));

        _liquidityDispatcher(orders, matching);
    }

    //---------------------------- DISPATCHER ----------------------------

    /// @dev Determines with what type of liquidity shall we match each order.
    function _liquidityDispatcher(
        ResolvedOrder[] calldata _orders,
        Matching[] memory _matching
    ) internal {
        if (_orders.length != _matching.length) revert OrdersLengthMismatch();

        unchecked {
            uint256 _onChainProp;

            for (uint256 i = 0; i < _orders.length; ++i) {
                _onChainProp = _matching[i].onChainMatch.onChainProportion;

                if (_onChainProp > 0) {
                    _matchWithOnChainLiquidity(
                        _orders[i],
                        _onChainProp,
                        _matching[i].onChainMatch.payAmt
                    );
                }

                /// @dev If on-chain prop. isn't 100%, match with off-chain orders.
                if (_onChainProp < 1e18) {
                    // _matchWithOffChainLiquidity(_orders[i], orders to match with);
                }
            }
        }
    }

    //---------------------------- EXECUTION ----------------------------

    /// @dev Trade order against 'RubiconMarket' on-chain liquidity.
    function _matchWithOnChainLiquidity(
        ResolvedOrder calldata _order,
        uint256 _proportion,
        uint256 _payAmt
    ) internal {
        if (_order.outputs.length > 1) revert IncorrectOutLength();

        IERC20 _payGem = IERC20(address(_order.input.token));
        IERC20 _buyGem = IERC20(address(_order.outputs[0].token));

        /// @dev Proportion defines, how much of input
        ///      amount, should be traded against on-chain liq.
        _payAmt = _payAmt.mulDivDown(_proportion, FixedPointMathLib.WAD);
        uint256 _buyAmt = _order.outputs[0].amount;

        /// @dev Load addresses to memory.
        IRubiconMarket _market = rubiMarket;
        address _reactor = address(reactor);

        if (_payGem.allowance(address(this), address(_market)) < _payAmt)
            _payGem.approve(address(_market), type(uint256).max);

        /// @dev We don't verify the output, because it will be
        ///      validated by a Reactor contract.
        _market.buyAllAmount(_buyGem, _buyAmt, _payGem, _payAmt);

        if (_buyGem.allowance(address(this), _reactor) < _buyAmt)
            _buyGem.approve(_reactor, type(uint256).max);
    }

    // TODO: implement
    /*function _matchWtihOffChainLiquidity(
        ResolvedOrder calldata orders,
        bytes calldata callbackData
    ) internal {}*/
}
