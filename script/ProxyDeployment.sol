// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {TransparentUpgradeableProxy} from "../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeployProxy {
    address constant PROXY_ADMIN = 0x3D77f824910Eb37eEd65eB789139805b34D73807;
    
    function deployProxy(
        address _logic,
        bytes memory _data
    ) internal returns (address payable) {
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            _logic,
            PROXY_ADMIN,
            _data
        );

        return payable(address(proxy));
    }
}
