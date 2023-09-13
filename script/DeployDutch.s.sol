// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Script.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {DutchOrderReactor} from "../src/reactors/DutchOrderReactor.sol";
import {OrderQuoter} from "../src/lens/OrderQuoter.sol";
import {DeployPermit2} from "../test/util/DeployPermit2.sol";
import {MockERC20} from "../test/util/mock/MockERC20.sol";

struct DutchDeployment {
    IPermit2 permit2;
    DutchOrderReactor reactor;
    OrderQuoter quoter;
}

contract DeployDutch is Script, DeployPermit2 {
    IPermit2 constant PERMIT2 =
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    /// @dev My test address.
    address constant FEE_TO = 0x42dEe6d967C1AD5344e7975Cf02B42F860b94d00;

    function setUp() public {}

    function run() public returns (DutchDeployment memory deployment) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        /// @dev Permit2 already there
        /*if (address(PERMIT2).code.length == 0) {
            deployPermit2();
        }*/

        DutchOrderReactor reactor = new DutchOrderReactor{
            salt: keccak256("WOB_0")
        }(PERMIT2, address(0));
        console2.log("Dutch Reactor", address(reactor));

        /*OrderQuoter quoter = new OrderQuoter{salt: 0x00}();
        console2.log("Quoter", address(quoter));*/

        vm.stopBroadcast();

        //return DutchDeployment(PERMIT2, reactor, quoter);
    }
}
