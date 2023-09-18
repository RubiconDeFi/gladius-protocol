// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ResolvedOrder, OutputToken, SignedOrder} from "../base/ReactorStructs.sol";
import {IReactorCallback} from "../interfaces/IReactorCallback.sol";
import {IRubiconMarket} from "../interfaces/IRubiconMarket.sol";
import {IReactor} from "../interfaces/IReactor.sol";

/// @dev A contract, that contains storage and helper funcs for 'RubiconExecutor'.
abstract contract ProcuratorBase is IReactorCallback {
    struct Matching {
        /// @dev Specify on-chain matching for order.
        OnChainMatch onChainMatch;
        /// @dev Specify off-chain matching for order.
        OffChainMatch[] offChainMatch;
    }

    struct OnChainMatch {
        /// @dev Percentage value in WAD.
        uint256 onChainProportion;
        uint256 payAmt;
    }

    struct OffChainMatch {
        /// @dev Percentage value in WAD.
        uint256 offChainProportion;
        uint256 offChainOrder;
    }

    //---------------------------- ERRORS ----------------------------

    /// @dev Thrown if 'reactorCallback' is called by a
    ///      non-permissioned filler.
    error CallerNotPermissioned();
    /// @dev Thrown if 'reactorCallback' is called by an
    ///      address other than the reactor
    error CallerNotReactor();
    /// @dev Thrown if '_orders' and '_matching' have different lengths.
    error OrdersLengthMismatch();
    /// @dev Thrown if the lenght of 'output' amounts.
    error IncorrectOutLength();

    //---------------------------- STORAGE ----------------------------

    bool public initialized;
    /// @dev Permissioned caller of this contract.
    address public admin;
    IRubiconMarket public rubiMarket;
    // TODO[1]: use 1 or multiple reactors?
    IReactor public reactor;

    //---------------------------- MODIFIERS ----------------------------

    modifier onlyPermissioned() {
        if (msg.sender != admin) {
            revert CallerNotPermissioned();
        }
        _;
    }

    modifier onlyReactor() {
        if (msg.sender != address(reactor)) {
            revert CallerNotReactor();
        }
        _;
    }

    //---------------------------- PROXY-INIT ----------------------------

    function initialize(
        address _admin,
        address _rubiMarket,
        address _reactor
    ) external {
        require(!initialized);
        admin = _admin;
        rubiMarket = IRubiconMarket(_rubiMarket);
        reactor = IReactor(_reactor);

        initialized = true;
    }

    //---------------------------- MAIN ----------------------------

    function execute(
        SignedOrder calldata order,
        bytes calldata callbackData
    ) external virtual;

    /*function executeBatch(
        SignedOrder[] calldata order,
        bytes[] calldata callbackData
    ) external virtual;*/

    /// @dev Main entry-point for 'Reactor'.
    function reactorCallback(
        ResolvedOrder[] calldata,
        bytes calldata callbackData
    ) external virtual;
}
