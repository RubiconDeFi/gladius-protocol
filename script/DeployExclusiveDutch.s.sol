// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {ExclusiveDutchOrderReactor} from "../src/reactors/ExclusiveDutchOrderReactor.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {DeployPermit2} from "../test/util/DeployPermit2.sol";
import {OrderQuoter} from "../src/lens/OrderQuoter.sol";
import {DeployProxy} from "./ProxyDeployment.sol";
import "forge-std/console2.sol";
import "forge-std/Script.sol";

struct ExclusiveDutchDeployment {
    IPermit2 permit2;
    ExclusiveDutchOrderReactor reactor;
    OrderQuoter quoter;
}

contract DeployExclusiveDutch is Script, DeployPermit2, DeployProxy {
    IPermit2 constant PERMIT2 =
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant RUBICON_ETH = 0x3204AC6F848e05557c6c7876E09059882e07962F;

    function setUp() public {}

    function run() public returns (ExclusiveDutchDeployment memory deployment) {
        vm.startBroadcast();
        if (address(PERMIT2).code.length == 0) {
            deployPermit2();
        }

        ExclusiveDutchOrderReactor reactor = new ExclusiveDutchOrderReactor();
        console2.log(
            "ExclusiveDutchOrderReactor implementation",
            address(reactor)
        );

        address payable proxy = deployProxy(address(reactor), "");
        console.log("Proxy for 'ExclusiveDutchOrderReactor':", proxy);

        ExclusiveDutchOrderReactor(proxy).initialize(address(PERMIT2), RUBICON_ETH);
        console.log("Proxy is initialized");

        OrderQuoter quoter = new OrderQuoter();
        console2.log("Quoter", address(quoter));

        vm.stopBroadcast();

        return
            ExclusiveDutchDeployment(
                IPermit2(PERMIT2),
                ExclusiveDutchOrderReactor(proxy),
                quoter
            );
    }
}
