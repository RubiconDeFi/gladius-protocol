// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {DutchOrderReactor, DutchOrder, DutchInput, DutchOutput} from "../src/reactors/DutchOrderReactor.sol";
import {OutputsBuilder} from "../test/util/OutputsBuilder.sol";
import {OrderInfoBuilder} from "../test/util/OrderInfoBuilder.sol";
import {OutputToken, InputToken, OrderInfo, ResolvedOrder, SignedOrder} from "../src/base/ReactorStructs.sol";
import "forge-std/console2.sol";
import "forge-std/Script.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {PermitSignature} from "../test/util/PermitSignature.sol";
import {DutchOrderReactor} from "../src/reactors/DutchOrderReactor.sol";
import {OrderQuoter} from "../src/lens/OrderQuoter.sol";
import {DeployPermit2} from "../test/util/DeployPermit2.sol";
import {MockERC20} from "../test/util/mock/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

struct DutchDeployment {
    IPermit2 permit2;
    DutchOrderReactor reactor;
    OrderQuoter quoter;
}

contract DeployDutch is Script, DeployPermit2, PermitSignature {
    using OrderInfoBuilder for OrderInfo;

    IPermit2 constant PERMIT2 =
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    /// @dev My test address.
    OrderQuoter public quoter =
        OrderQuoter(0x3DE6B223DE796aBe6590d927B47A37dCF6d2771e);
    DutchOrderReactor reactor =
        DutchOrderReactor(payable(0xFeF57fD5622EB4627b32642Ac0a010353f487090));
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    function setUp() public {}

    function run() public returns (DutchDeployment memory deployment) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(deployerPrivateKey);
        uint256 dudePk = 0x12341235;
        address dude = vm.addr(dudePk);

        vm.startBroadcast(deployerPrivateKey);

        tokenIn = new MockERC20("Input", "IN", 18);
        tokenOut = new MockERC20("Output", "OUT", 18);

        /// @dev Swapper receives his tokens
        tokenIn.mint(dude, type(uint128).max);
        /// @dev Filler receives tokens to pay.
        tokenOut.mint(me, type(uint128).max);

        //tokenIn.mint(address(reactor), type(uint128).max);
        //tokenOut.mint(address(reactor), type(uint128).max);

        //tokenIn.approve(address(PERMIT2), type(uint64).max);
        //tokenIn.approve(address(reactor), type(uint64).max);

        tokenIn.forceApprove(dude, address(PERMIT2), type(uint64).max);
        //tokenIn.forceApprove(me, dude, type(uint64).max);
        tokenOut.forceApprove(me, address(reactor), type(uint64).max);

        // 2.

        DutchOrder memory order = DutchOrder({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(dude)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp - 1,
            decayEndTime: block.timestamp + 1,
            input: DutchInput(tokenIn, 1, 1),
            outputs: OutputsBuilder.singleDutch(address(tokenOut), 1, 1, dude)
        });

        reactor.execute(
            SignedOrder(
                abi.encode(order),
                signOrder(dudePk, address(PERMIT2), order)
            )
        );

        /*quoter.quote(
            abi.encode(order),
            signOrder(deployerPrivateKey, address(PERMIT2), order)
        );*/

        vm.stopBroadcast();

        //return DutchDeployment(PERMIT2, reactor, quoter);
    }
}
