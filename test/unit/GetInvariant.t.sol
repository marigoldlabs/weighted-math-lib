// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.19;

import "lib/forge-std/src/Test.sol";
import { WeightedMathLib as Custom } from "src/WeightedMathLib.sol";
import { WeightedMathLib as Reference } from "../Reference.sol";

uint256 constant amountIn = 1 ether;
uint256 constant amountOut = 1 ether;
uint256 constant reserveIn = 100 ether;
uint256 constant reserveOut = 100 ether;
uint256 constant weightIn = 0.6 ether;
uint256 constant weightOut = 0.4 ether;
uint256 constant invariant = 100 ether;

uint256 constant ACCEPTABLE_RELATIVE_SWAP_ERROR = 50000;
uint256 constant ACCEPTABLE_RELATIVE_INVARIANT_ERROR = 20000;

contract GetInvariantTest is Test {
    /// -----------------------------------------------------------------------
    /// Unit
    /// -----------------------------------------------------------------------

    function testGetInvariantCorrectness() public {
        uint256[] memory reserves = new uint256[](2);
        reserves[0] = reserveIn;
        reserves[1] = reserveOut;

        uint256[] memory weights = new uint256[](2);
        weights[0] = weightIn;
        weights[1] = weightOut;

        uint256 customTwoToken = Custom.getInvariant(reserves, weights);
        uint256 customMultitoken = Custom.getInvariant(reserveIn, reserveOut, weightIn, weightOut);
        uint256 referenceMultitoken = Reference._calculateInvariant(weights, reserves);

        assertEq(customTwoToken, customMultitoken);
        assertEq(customMultitoken, referenceMultitoken);
    }

    /// -----------------------------------------------------------------------
    /// Fuzz
    /// -----------------------------------------------------------------------

    /// -----------------------------------------------------------------------
    /// Gas
    /// -----------------------------------------------------------------------
}

// contract WeightedMathLibTest is Test {
//     uint256 ACCEPTABLE_RELATIVE_SWAP_ERROR = 50000;
//     uint256 ACCEPTABLE_RELATIVE_INVARIANT_ERROR = 20000;

//     function testGetInvariant() public {
//         uint256[] memory reserves = new uint256[](2);
//         reserves[0] = reserveIn;
//         reserves[1] = reserveOut;

//         uint256[] memory weights = new uint256[](2);
//         weights[0] = weightIn;
//         weights[1] = weightOut;

//         uint256 a = Custom.getInvariant(reserves, weights);
//         uint256 b =
//             Custom.getInvariant(reserveIn, reserveOut, weightIn, weightOut);
//         uint256 c = Reference._calculateInvariant(weights, reserves);

//         assertEq(a, b);
//         assertApproxEqRel(b, c, ACCEPTABLE_RELATIVE_INVARIANT_ERROR);
//     }

//     function testGetAmountIn() public {
//         assertApproxEqRel(
//             Custom.getAmountIn(
//                 amountOut, reserveIn, reserveOut, weightIn, weightOut
//             ),
//             Reference._calcInGivenOut(
//                 reserveIn, weightIn, reserveOut, weightOut, amountOut
//             ),
//             ACCEPTABLE_RELATIVE_SWAP_ERROR
//         );
//     }

//     function testGetAmountOut() public {
//         assertApproxEqRel(
//             Custom.getAmountOut(
//                 amountIn, reserveIn, reserveOut, weightIn, weightOut
//             ),
//             Reference._calcOutGivenIn(
//                 reserveIn, weightIn, reserveOut, weightOut, amountIn
//             ),
//             ACCEPTABLE_RELATIVE_SWAP_ERROR
//         );
//     }

//     function testRoundTripGetAmountOut() public {
//         uint256 invariantBefore =
//             Custom.getInvariant(reserveIn, reserveOut, weightIn, weightOut);

//         uint256 invariantAfter = Custom.getInvariant(
//             reserveIn + amountIn,
//             reserveOut
//                 - Custom.getAmountOut(
//                     amountIn, reserveIn, reserveOut, weightIn, weightOut
//                 ),
//             weightIn,
//             weightOut
//         );

//         assertTrue(invariantBefore <= invariantAfter);
//     }
// }
