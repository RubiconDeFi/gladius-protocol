// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Script.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {ExclusiveDutchOrderReactor} from "../src/reactors/ExclusiveDutchOrderReactor.sol";
import {OrderQuoter} from "../src/lens/OrderQuoter.sol";
import {DeployPermit2} from "../test/util/DeployPermit2.sol";

struct ExclusiveDutchDeployment {
    IPermit2 permit2;
    ExclusiveDutchOrderReactor reactor;
    OrderQuoter quoter;
}

contract DeployExclusiveDutch is Script, DeployPermit2 {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function setUp() public {}

    function run() public returns (ExclusiveDutchDeployment memory deployment) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        /// @dev Permit2 already there
        /*if (PERMIT2.code.length == 0) {
            deployPermit2();
        }*/

        ExclusiveDutchOrderReactor reactor = new ExclusiveDutchOrderReactor{
            salt: keccak256("WOB_1")
        }(IPermit2(PERMIT2), address(0));
        console2.log("ExDutch Reactor", address(reactor));

        //OrderQuoter quoter = new OrderQuoter{salt: 0x00}();
        //console2.log("Quoter", address(quoter));

        vm.stopBroadcast();

        //return ExclusiveDutchDeployment(IPermit2(PERMIT2), reactor, quoter);
    }
}
