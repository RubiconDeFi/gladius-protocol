// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {LimitOrderReactor} from "../src/reactors/LimitOrderReactor.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {DeployPermit2} from "../test/util/DeployPermit2.sol";
import {MockERC20} from "../test/util/mock/MockERC20.sol";
import {OrderQuoter} from "../src/lens/OrderQuoter.sol";
import {DeployProxy} from "./ProxyDeployment.sol";
import "forge-std/console.sol";
import "forge-std/Script.sol";

struct LimitDeployment {
    IPermit2 permit2;
    LimitOrderReactor reactor;
    OrderQuoter quoter;
}

contract DeployLimit is Script, DeployPermit2, DeployProxy {
    IPermit2 constant PERMIT2 =
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant RUBICON_ETH = 0x3204AC6F848e05557c6c7876E09059882e07962F;

    function setUp() public {}

    function run() public returns (LimitDeployment memory deployment) {
        vm.startBroadcast();
        if (address(PERMIT2).code.length == 0) {
            deployPermit2();
        }

        LimitOrderReactor reactor = new LimitOrderReactor();
        console.log("LimitOrderReactor implementation:", address(reactor));

        address payable proxy = deployProxy(address(reactor), "");
        console.log("Proxy for 'LimitOrderReactor':", proxy);
        LimitOrderReactor(proxy).initialize(address(PERMIT2), RUBICON_ETH);
        console.log("Proxy is initialized");

        OrderQuoter quoter = new OrderQuoter();
        console.log("Quoter", address(quoter));

        vm.stopBroadcast();

        return LimitDeployment(PERMIT2, LimitOrderReactor(proxy), quoter);
    }
}
