// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {DutchOrderReactor} from "../src/reactors/DutchOrderReactor.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {DeployPermit2} from "../test/util/DeployPermit2.sol";
import {MockERC20} from "../test/util/mock/MockERC20.sol";
import {OrderQuoter} from "../src/lens/OrderQuoter.sol";
import {DeployProxy} from "./ProxyDeployment.sol";
import "forge-std/console.sol";
import "forge-std/Script.sol";

struct DutchDeployment {
    IPermit2 permit2;
    DutchOrderReactor reactor;
    OrderQuoter quoter;
}

contract DeployDutch is Script, DeployPermit2, DeployProxy {
    IPermit2 constant PERMIT2 =
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant RUBICON_ETH = 0x3204AC6F848e05557c6c7876E09059882e07962F;

    function setUp() public {}

    function run() public returns (DutchDeployment memory deployment) {
        vm.startBroadcast();
        if (address(PERMIT2).code.length == 0) {
            deployPermit2();
        }

        DutchOrderReactor reactor = new DutchOrderReactor();
        console.log("DutchOrderReactor implementation:", address(reactor));

        address payable proxy = deployProxy(address(reactor), "");
        console.log("Proxy for 'DutchOrderReactor':", proxy);
        DutchOrderReactor(proxy).initialize(PERMIT2, RUBICON_ETH);
        console.log("Proxy is initialized");

        OrderQuoter quoter = new OrderQuoter();
        console.log("Quoter", address(quoter));

        vm.stopBroadcast();

        return DutchDeployment(PERMIT2, DutchOrderReactor(proxy), quoter);
    }
}
