// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.19;

import "lib/forge-std/src/Test.sol";
import "src/WeightedMathLib.sol";

contract LinearInterpolationTest is Test {
    /// -----------------------------------------------------------------------
    /// Unit
    /// -----------------------------------------------------------------------

    function testValueCannotDecreaseMoreThanDelta() public {
        // Assert x cannot decrease more than (x-y).
        assertEq(
            WeightedMathLib.linearInterpolation({ x: 1_000 ether, y: 100 ether, i: 11, n: 10 }),
            100 ether
        );
    }

    function testValueCannotIncreaseMoreThanDelta() public {
        // Assert x cannot increase more than (y-x).
        assertEq(
            WeightedMathLib.linearInterpolation({ x: 100 ether, y: 1_000 ether, i: 11, n: 10 }),
            1000 ether
        );
    }

    /// -----------------------------------------------------------------------
    /// Fuzz
    /// -----------------------------------------------------------------------

    /// @dev Using uint128 for fuzzing to avoid i*n overflow.
    /// type(uint128).max**2 == type(uint256).max
    function testValueCannotDecreaseMoreThanDelta(uint128 i, uint128 n) public {
        vm.assume(i > n);
        vm.assume(n > 0);

        // Assert x cannot decrease more than (x-y).
        assertEq(
            WeightedMathLib.linearInterpolation({ x: 1_000 ether, y: 100 ether, i: i, n: n }),
            100 ether
        );
    }

    /// @dev Using uint128 for fuzzing to avoid i*n overflow.
    /// type(uint128).max**2 == type(uint256).max
    function testValueCannotIncreaseMoreThanDelta(uint128 i, uint128 n) public {
        vm.assume(i > n);
        vm.assume(n > 0);

        // Assert x cannot increase more than (y-x).
        assertEq(
            WeightedMathLib.linearInterpolation({ x: 100 ether, y: 1_000 ether, i: i, n: n }),
            1000 ether
        );
    }

    /// -----------------------------------------------------------------------
    /// Gas
    /// -----------------------------------------------------------------------

    function testGas() public {
        uint256 gasBefore = gasleft();

        WeightedMathLib.linearInterpolation({ x: 100 ether, y: 1_000 ether, i: 11, n: 10 });

        uint256 gasAfter = gasleft();

        unchecked {
            console.log(gasBefore - gasAfter);
        }
    }
}
