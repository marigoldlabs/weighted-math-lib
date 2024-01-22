// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.19;

import "lib/solplot/src/Plot.sol";
import "src/WeightedMathLib.sol";

contract WeightedMathLibPlot is Plot {
    /// -----------------------------------------------------------------------
    /// Test Constants
    /// -----------------------------------------------------------------------

    uint256 constant amountIn = 1 ether;
    uint256 constant reserveIn = 100 ether;
    uint256 constant reserveOut = 100 ether;
    uint256 constant weightInStarting = 0.01 ether;
    uint256 constant weightInEnding = 0.2 ether;
    uint256 constant length = 100;

    /// -----------------------------------------------------------------------
    /// Linear LBP Plot
    /// -----------------------------------------------------------------------

    function testPlotLinearLBP() public {
        try vm.removeFile("input.csv") { } catch { }

        uint256[] memory columns = new uint256[](4);

        unchecked {
            for (uint256 index = 0; index < length; index++) {
                uint256 weightIn = WeightedMathLib.linearInterpolation(
                    weightInStarting, weightInEnding, index, length
                );
                uint256 weightOut = 1e18 - weightIn;

                columns[0] = index * 1e18;

                columns[1] =
                    WeightedMathLib.getSpotPrice(reserveIn, reserveOut, weightIn, weightOut);

                columns[2] = weightIn;

                columns[3] = weightOut;

                writeRowToCSV("input.csv", columns);
            }
        }

        plot({
            inputCsv: "input.csv",
            outputSvg: "output.svg",
            inputDecimals: 18,
            totalColumns: 4,
            legend: false
        });
    }
}
