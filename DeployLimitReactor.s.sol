// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Script.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {LimitOrderReactor} from "../src/reactors/LimitOrderReactor.sol";
import {OrderQuoter} from "../src/lens/OrderQuoter.sol";
import {DeployPermit2} from "../test/util/DeployPermit2.sol";

contract DeployLimitReactor is Script, DeployPermit2 {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev My test address.
    //address constant FEE_TO = 0x42dEe6d967C1AD5344e7975Cf02B42F860b94d00;

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        /// @dev Permit2 already there
        /*if (PERMIT2.code.length == 0) {
            deployPermit2();
        }*/

        /// @dev FEE_TO isn't set for now.
        LimitOrderReactor reactor = new LimitOrderReactor{
            salt: keccak256("WOB_2")
        }(IPermit2(PERMIT2), address(0));
        console2.log("Limit Order Reactor", address(reactor));

        OrderQuoter quoter = new OrderQuoter{salt: keccak256("fuck AMMs")}();
        console2.log("Quoter", address(quoter));

        vm.stopBroadcast();

        //return ExclusiveDutchDeployment(IPermit2(PERMIT2), reactor, quoter);
    }
}
