// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {InputToken, OutputToken} from "../../src/base/ReactorStructs.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {PartialFillLib} from "../../src/lib/PartialFillLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract PartialFillLibTest is Test {
    using FixedPointMathLib for uint256;
    using PartialFillLib for uint256;

    ERC20 private constant t = ERC20(address(0));

    function testFuzz_ThresholdValidation(
        uint256 fillThreshold,
        uint256 inputAmount
    ) public pure {
        vm.assume(fillThreshold <= inputAmount);

        fillThreshold._validateThreshold(inputAmount);
    }

    function testFuzz_ApplyPartition0Threshold(
        uint256 inAmt,
        uint256 outAmt,
        uint256 quantity
    ) public {
	uint256 fillThreshold = 0;
	
        // avoid infamous overflow...
        inAmt = bound(inAmt, 1e3, type(uint128).max);
        outAmt = bound(outAmt, 1e3, type(uint128).max);

        InputToken memory input = InputToken(t, inAmt, inAmt);
        OutputToken[] memory output = new OutputToken[](1);
        output[0] = OutputToken(address(t), outAmt, address(t));
       
        vm.assume(quantity <= 10 && quantity > 0);

        // Mutate i/o structs.
        (InputToken memory i, OutputToken[] memory o) = quantity.partition(
            input,
            output,
            fillThreshold
        );

        assertLe(i.amount, input.amount);
        assertGe(i.amount, fillThreshold);

        assertLe(o[0].amount, output[0].amount);

        uint256 initialExchangeRate = input.amount >= output[0].amount
            ? input.amount.divWadUp(output[0].amount)
            : output[0].amount.divWadUp(input.amount);

        uint256 newExchangeRate = input.amount >= output[0].amount
            ? i.amount.divWadUp(o[0].amount)
            : o[0].amount.divWadUp(i.amount);

        // Double-check that we won't break initial exchange rate.
        assertEq(newExchangeRate, initialExchangeRate);
    }

    function testFuzz_ApplyPartition(
        uint256 inAmt,
        uint256 outAmt,
        uint256 fillThreshold,
        uint256 quantity
    ) public {
        // avoid infamous overflow...
        inAmt = bound(inAmt, 1e3, type(uint128).max);
        outAmt = bound(outAmt, 1e3, type(uint128).max);

        InputToken memory input = InputToken(t, inAmt, inAmt);
        OutputToken[] memory output = new OutputToken[](1);
        output[0] = OutputToken(address(t), outAmt, address(t));

        vm.assume(fillThreshold > 0 && fillThreshold <= inAmt);
        vm.assume(quantity >= fillThreshold && quantity <= inAmt);

        // Mutate i/o structs.
        (InputToken memory i, OutputToken[] memory o) = quantity.partition(
            input,
            output,
            fillThreshold
        );

        assertLe(i.amount, input.amount);
        assertGe(i.amount, fillThreshold);

        assertLe(o[0].amount, output[0].amount);

        uint256 initialExchangeRate = input.amount >= output[0].amount
            ? input.amount.divWadUp(output[0].amount)
            : output[0].amount.divWadUp(input.amount);

        uint256 newExchangeRate = input.amount >= output[0].amount
            ? i.amount.divWadUp(o[0].amount)
            : o[0].amount.divWadUp(i.amount);

        // Double-check that we won't break initial exchange rate.
        assertEq(newExchangeRate, initialExchangeRate);
    }

    function testFuzz_AllPartialFillErrors(
        uint256 quantity,
        uint256 outPart,
        uint256 initIn,
        uint256 initOut,
        uint256 fillThreshold
    ) public {
        vm.assume(quantity > initIn || outPart > initOut);
        vm.expectRevert(bytes4(keccak256("PartialFillOverflow()")));
        quantity._validatePartition(outPart, initIn, initOut, fillThreshold);

        vm.assume(quantity == 0 || outPart == 0);
        vm.expectRevert(bytes4(keccak256("PartialFillUnderflow()")));
        quantity._validatePartition(outPart, initIn, initOut, fillThreshold);

        vm.assume(quantity < fillThreshold);
        vm.expectRevert(bytes4(keccak256("QuantityLtThreshold()")));
        quantity._validatePartition(outPart, initIn, initOut, fillThreshold);

        vm.assume(fillThreshold > initIn);
        vm.expectRevert(bytes4(keccak256("InvalidThreshold()")));
        fillThreshold._validateThreshold(initIn);
    }
}
