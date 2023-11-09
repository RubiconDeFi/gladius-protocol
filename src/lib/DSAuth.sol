// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/// @notice DSAuth events for authentication schema
contract DSAuthEvents {
    event LogSetOwner(address indexed owner);
}

/// @notice DSAuth library for setting owner of the contract
/// @dev Provides the auth modifier for authenticated function calls
contract DSAuth is DSAuthEvents {
    address public owner;

    error Unauthorized();

    function setOwner(address owner_) external auth {
        owner = owner_;
        emit LogSetOwner(owner);
    }

    modifier auth() {
        if (!isAuthorized(msg.sender)) revert Unauthorized();
        _;
    }

    function isAuthorized(address src) internal view returns (bool) {
        if (src == owner) {
            return true;
        } else {
            return false;
        }
    }
}
