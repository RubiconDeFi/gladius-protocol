// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {GladiusOrderQuoter} from "../src/lens/GladiusOrderQuoter.sol";
import {GladiusReactor} from "../src/reactors/GladiusReactor.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {DeployPermit2} from "../test/util/DeployPermit2.sol";
import {DeployProxy} from "./ProxyDeployment.sol";
import "forge-std/console2.sol";
import "forge-std/Script.sol";

struct GladiusDeployment {
    IPermit2 permit2;
    GladiusReactor reactor;
    GladiusOrderQuoter quoter;
}

contract DeployGladiusReactor is Script, DeployPermit2, DeployProxy {
    IPermit2 constant PERMIT2 =
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant RUBICON_ETH = 0xC96495C314879586761d991a2B68ebeab12C03FE;

    function setUp() public {}

    function run() public returns (GladiusDeployment memory deployment) {
        vm.startBroadcast();
        if (address(PERMIT2).code.length == 0) {
            deployPermit2();
        }

        GladiusReactor reactor = new GladiusReactor{salt: bytes32(uint256(1))}();
        console2.log("GladiusReactor implementation", address(reactor));

        address payable proxy = deployProxy(address(reactor), "");
        console2.log("Proxy for 'GladiusReactor':", proxy);

        GladiusReactor(proxy).initialize(address(PERMIT2), RUBICON_ETH);
        console2.log("Proxy is initialized");

        GladiusOrderQuoter quoter = new GladiusOrderQuoter{salt: bytes32(uint256(2))}();
        console2.log("Quoter", address(quoter));

        vm.stopBroadcast();

        return GladiusDeployment(IPermit2(PERMIT2), reactor, quoter);
    }
}
