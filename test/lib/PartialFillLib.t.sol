// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {PartialFillLib} from "../../src/lib/PartialFillLib.sol";
import {Test} from "forge-std/Test.sol";

contract PartialFillLibTest is Test {
    using PartialFillLib for uint256;

    function test_ThresholdValidation(
        uint256 fillThreshold,
        uint256 inputAmount
    ) public {
        vm.assume(fillThreshold <= inputAmount);

        /// @dev It will revert in case of an error.
        fillThreshold._validateThreshold(inputAmount);
    }
}
