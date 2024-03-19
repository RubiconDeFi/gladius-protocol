// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract ProxyConstructor {
    error AlreadyInitialized();

    bool public initialized;

    function initialize(address addr0, address addr1) external virtual {}
}
