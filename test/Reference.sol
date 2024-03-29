// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.19;

library WeightedMathLib {
    using FixedPoint for uint256;
    // A minimum normalized weight imposes a maximum weight ratio. We need this due to limitations in the
    // implementation of the power function, as these ratios are often exponents.

    uint256 internal constant _MIN_WEIGHT = 0.01e18;
    // Having a minimum normalized weight imposes a limit on the maximum number of tokens;
    // i.e., the largest possible pool is one where all tokens have exactly the minimum weight.
    uint256 internal constant _MAX_WEIGHTED_TOKENS = 100;

    // Pool limits that arise from limitations in the fixed point power function (and the imposed 1:100 maximum weight
    // ratio).

    // Swap limits: amounts swapped may not be larger than this percentage of total balance.
    uint256 internal constant _MAX_IN_RATIO = 0.3e18;
    uint256 internal constant _MAX_OUT_RATIO = 0.3e18;

    // Invariant growth limit: non-proportional joins cannot cause the invariant to increase by more than this ratio.
    uint256 internal constant _MAX_INVARIANT_RATIO = 3e18;
    // Invariant shrink limit: non-proportional exits cannot cause the invariant to decrease by less than this ratio.
    uint256 internal constant _MIN_INVARIANT_RATIO = 0.7e18;

    // About swap fees on joins and exits:
    // Any join or exit that is not perfectly balanced (e.g. all single token joins or exits) is mathematically
    // equivalent to a perfectly balanced join or exit followed by a series of swaps. Since these swaps would charge
    // swap fees, it follows that (some) joins and exits should as well.
    // On these operations, we split the token amounts in 'taxable' and 'non-taxable' portions, where the 'taxable' part
    // is the one to which swap fees are applied.

    // Invariant is used to collect protocol swap fees by comparing its value between two times.
    // So we can round always to the same direction. It is also used to initiate the BPT amount
    // and, because there is a minimum BPT, we round down the invariant.
    function _calculateInvariant(uint256[] memory normalizedWeights, uint256[] memory balances)
        internal
        pure
        returns (uint256 invariant)
    {
        /**
         *
         *     // invariant               _____                                                             //
         *     // wi = weight index i      | |      wi                                                      //
         *     // bi = balance index i     | |  bi ^   = i                                                  //
         *     // i = invariant                                                                             //
         *
         */
        unchecked {
            invariant = FixedPoint.ONE;
            for (uint256 i = 0; i < normalizedWeights.length; i++) {
                invariant = invariant.mulDown(balances[i].powDown(normalizedWeights[i]));
            }

            _require(invariant > 0, Errors.ZERO_INVARIANT);
        }
    }

    // Computes how many tokens can be taken out of a pool if `amountIn` are sent, given the
    // current balances and weights.
    function _calcOutGivenIn(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountIn
    ) internal pure returns (uint256) {
        /**
         *
         *     // outGivenIn                                                                                //
         *     // aO = amountOut                                                                            //
         *     // bO = balanceOut                                                                           //
         *     // bI = balanceIn              /      /            bI             \    (wI / wO) \           //
         *     // aI = amountIn    aO = bO * |  1 - | --------------------------  | ^            |          //
         *     // wI = weightIn               \      \       ( bI + aI )         /              /           //
         *     // wO = weightOut                                                                            //
         *
         */

        // Amount out, so we round down overall.

        // The multiplication rounds down, and the subtrahend (power) rounds up (so the base rounds up too).
        // Because bI / (bI + aI) <= 1, the exponent rounds down.

        // Cannot exceed maximum in ratio
        _require(amountIn <= balanceIn.mulDown(_MAX_IN_RATIO), Errors.MAX_IN_RATIO);

        uint256 denominator = balanceIn.add(amountIn);
        uint256 base = balanceIn.divUp(denominator);
        uint256 exponent = weightIn.divDown(weightOut);
        uint256 power = base.powUp(exponent);

        return balanceOut.mulDown(power.complement());
    }

    // Computes how many tokens must be sent to a pool in order to take `amountOut`, given the
    // current balances and weights.
    function _calcInGivenOut(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountOut
    ) internal pure returns (uint256) {
        /**
         *
         *     // inGivenOut                                                                                //
         *     // aO = amountOut                                                                            //
         *     // bO = balanceOut                                                                           //
         *     // bI = balanceIn              /  /            bO             \    (wO / wI)      \          //
         *     // aI = amountIn    aI = bI * |  | --------------------------  | ^            - 1  |         //
         *     // wI = weightIn               \  \       ( bO - aO )         /                   /          //
         *     // wO = weightOut                                                                            //
         *
         */

        // Amount in, so we round up overall.

        // The multiplication rounds up, and the power rounds up (so the base rounds up too).
        // Because b0 / (b0 - a0) >= 1, the exponent rounds up.

        // Cannot exceed maximum out ratio
        _require(amountOut <= balanceOut.mulDown(_MAX_OUT_RATIO), Errors.MAX_OUT_RATIO);

        uint256 base = balanceOut.divUp(balanceOut.sub(amountOut));
        uint256 exponent = weightOut.divUp(weightIn);
        uint256 power = base.powUp(exponent);

        // Because the base is larger than one (and the power rounds up), the power should always be larger than one, so
        // the following subtraction should never revert.
        uint256 ratio = power.sub(FixedPoint.ONE);

        return balanceIn.mulUp(ratio);
    }

    function _calcBptOutGivenExactTokensIn(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsIn,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        // BPT out, so we round down overall.

        unchecked {
            uint256[] memory balanceRatiosWithFee = new uint256[](amountsIn.length);

            uint256 invariantRatioWithFees = 0;
            for (uint256 i = 0; i < balances.length; i++) {
                balanceRatiosWithFee[i] = balances[i].add(amountsIn[i]).divDown(balances[i]);
                invariantRatioWithFees = invariantRatioWithFees.add(
                    balanceRatiosWithFee[i].mulDown(normalizedWeights[i])
                );
            }

            uint256 invariantRatio = _computeJoinExactTokensInInvariantRatio(
                balances,
                normalizedWeights,
                amountsIn,
                balanceRatiosWithFee,
                invariantRatioWithFees,
                swapFeePercentage
            );

            uint256 bptOut = (invariantRatio > FixedPoint.ONE)
                ? bptTotalSupply.mulDown(invariantRatio - FixedPoint.ONE)
                : 0;
            return bptOut;
        }
    }

    function _calcBptOutGivenExactTokenIn(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 amountIn,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        // BPT out, so we round down overall.

        unchecked {
            uint256 amountInWithoutFee;
            {
                uint256 balanceRatioWithFee = balance.add(amountIn).divDown(balance);

                // The use of `normalizedWeight.complement()` assumes that the sum of all weights equals FixedPoint.ONE.
                // This may not be the case when weights are stored in a denormalized format or during a gradual weight
                // change due rounding errors during normalization or interpolation. This will result in a small difference
                // between the output of this function and the equivalent `_calcBptOutGivenExactTokensIn` call.
                uint256 invariantRatioWithFees =
                    balanceRatioWithFee.mulDown(normalizedWeight).add(normalizedWeight.complement());

                if (balanceRatioWithFee > invariantRatioWithFees) {
                    uint256 nonTaxableAmount = invariantRatioWithFees > FixedPoint.ONE
                        ? balance.mulDown(invariantRatioWithFees - FixedPoint.ONE)
                        : 0;
                    uint256 taxableAmount = amountIn.sub(nonTaxableAmount);
                    uint256 swapFee = taxableAmount.mulUp(swapFeePercentage);

                    amountInWithoutFee = nonTaxableAmount.add(taxableAmount.sub(swapFee));
                } else {
                    amountInWithoutFee = amountIn;
                    // If a token's amount in is not being charged a swap fee then it might be zero.
                    // In this case, it's clear that the sender should receive no BPT.
                    if (amountInWithoutFee == 0) {
                        return 0;
                    }
                }
            }

            uint256 balanceRatio = balance.add(amountInWithoutFee).divDown(balance);

            uint256 invariantRatio = balanceRatio.powDown(normalizedWeight);

            uint256 bptOut = (invariantRatio > FixedPoint.ONE)
                ? bptTotalSupply.mulDown(invariantRatio - FixedPoint.ONE)
                : 0;
            return bptOut;
        }
    }

    /**
     * @dev Intermediate function to avoid stack-too-deep errors.
     */
    function _computeJoinExactTokensInInvariantRatio(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsIn,
        uint256[] memory balanceRatiosWithFee,
        uint256 invariantRatioWithFees,
        uint256 swapFeePercentage
    ) private pure returns (uint256 invariantRatio) {
        unchecked {
            // Swap fees are charged on all tokens that are being added in a larger proportion than the overall invariant
            // increase.
            invariantRatio = FixedPoint.ONE;

            for (uint256 i = 0; i < balances.length; i++) {
                uint256 amountInWithoutFee;

                if (balanceRatiosWithFee[i] > invariantRatioWithFees) {
                    // invariantRatioWithFees might be less than FixedPoint.ONE in edge scenarios due to rounding error,
                    // particularly if the weights don't exactly add up to 100%.
                    uint256 nonTaxableAmount = invariantRatioWithFees > FixedPoint.ONE
                        ? balances[i].mulDown(invariantRatioWithFees - FixedPoint.ONE)
                        : 0;
                    uint256 swapFee = amountsIn[i].sub(nonTaxableAmount).mulUp(swapFeePercentage);
                    amountInWithoutFee = amountsIn[i].sub(swapFee);
                } else {
                    amountInWithoutFee = amountsIn[i];

                    // If a token's amount in is not being charged a swap fee then it might be zero (e.g. when joining a
                    // Pool with only a subset of tokens). In this case, `balanceRatio` will equal `FixedPoint.ONE`, and
                    // the `invariantRatio` will not change at all. We therefore skip to the next iteration, avoiding
                    // the costly `powDown` call.
                    if (amountInWithoutFee == 0) {
                        continue;
                    }
                }

                uint256 balanceRatio = balances[i].add(amountInWithoutFee).divDown(balances[i]);

                invariantRatio = invariantRatio.mulDown(balanceRatio.powDown(normalizedWeights[i]));
            }
        }
    }

    function _calcTokenInGivenExactBptOut(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 bptAmountOut,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        /**
         *
         *     // tokenInForExactBPTOut                                                                 //
         *     // a = amountIn                                                                          //
         *     // b = balance                      /  /    totalBPT + bptOut      \    (1 / w)       \  //
         *     // bptOut = bptAmountOut   a = b * |  | --------------------------  | ^          - 1  |  //
         *     // bpt = totalBPT                   \  \       totalBPT            /                  /  //
         *     // w = weight                                                                            //
         *
         */

        // Token in, so we round up overall.

        // Calculate the factor by which the invariant will increase after minting BPTAmountOut
        uint256 invariantRatio = bptTotalSupply.add(bptAmountOut).divUp(bptTotalSupply);
        _require(invariantRatio <= _MAX_INVARIANT_RATIO, Errors.MAX_OUT_BPT_FOR_TOKEN_IN);

        // Calculate by how much the token balance has to increase to match the invariantRatio
        uint256 balanceRatio = invariantRatio.powUp(FixedPoint.ONE.divUp(normalizedWeight));

        uint256 amountInWithoutFee = balance.mulUp(balanceRatio.sub(FixedPoint.ONE));

        // We can now compute how much extra balance is being deposited and used in virtual swaps, and charge swap fees
        // accordingly.
        uint256 taxableAmount = amountInWithoutFee.mulUp(normalizedWeight.complement());
        uint256 nonTaxableAmount = amountInWithoutFee.sub(taxableAmount);

        uint256 taxableAmountPlusFees = taxableAmount.divUp(swapFeePercentage.complement());

        return nonTaxableAmount.add(taxableAmountPlusFees);
    }

    function _calcBptInGivenExactTokensOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsOut,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        // BPT in, so we round up overall.

        unchecked {
            uint256[] memory balanceRatiosWithoutFee = new uint256[](amountsOut.length);
            uint256 invariantRatioWithoutFees = 0;
            for (uint256 i = 0; i < balances.length; i++) {
                balanceRatiosWithoutFee[i] = balances[i].sub(amountsOut[i]).divUp(balances[i]);
                invariantRatioWithoutFees = invariantRatioWithoutFees.add(
                    balanceRatiosWithoutFee[i].mulUp(normalizedWeights[i])
                );
            }

            uint256 invariantRatio = _computeExitExactTokensOutInvariantRatio(
                balances,
                normalizedWeights,
                amountsOut,
                balanceRatiosWithoutFee,
                invariantRatioWithoutFees,
                swapFeePercentage
            );

            return bptTotalSupply.mulUp(invariantRatio.complement());
        }
    }

    function _calcBptInGivenExactTokenOut(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 amountOut,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        // BPT in, so we round up overall.

        uint256 balanceRatioWithoutFee = balance.sub(amountOut).divUp(balance);

        uint256 invariantRatioWithoutFees =
            balanceRatioWithoutFee.mulUp(normalizedWeight).add(normalizedWeight.complement());

        uint256 amountOutWithFee;
        if (invariantRatioWithoutFees > balanceRatioWithoutFee) {
            // Swap fees are typically charged on 'token in', but there is no 'token in' here, so we apply it to
            // 'token out'. This results in slightly larger price impact.

            uint256 nonTaxableAmount = balance.mulDown(invariantRatioWithoutFees.complement());
            uint256 taxableAmount = amountOut.sub(nonTaxableAmount);
            uint256 taxableAmountPlusFees = taxableAmount.divUp(swapFeePercentage.complement());

            amountOutWithFee = nonTaxableAmount.add(taxableAmountPlusFees);
        } else {
            amountOutWithFee = amountOut;
            // If a token's amount out is not being charged a swap fee then it might be zero.
            // In this case, it's clear that the sender should not send any BPT.
            if (amountOutWithFee == 0) {
                return 0;
            }
        }

        uint256 balanceRatio = balance.sub(amountOutWithFee).divDown(balance);

        uint256 invariantRatio = balanceRatio.powDown(normalizedWeight);

        return bptTotalSupply.mulUp(invariantRatio.complement());
    }

    /**
     * @dev Intermediate function to avoid stack-too-deep errors.
     */
    function _computeExitExactTokensOutInvariantRatio(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsOut,
        uint256[] memory balanceRatiosWithoutFee,
        uint256 invariantRatioWithoutFees,
        uint256 swapFeePercentage
    ) private pure returns (uint256 invariantRatio) {
        unchecked {
            invariantRatio = FixedPoint.ONE;

            for (uint256 i = 0; i < balances.length; i++) {
                // Swap fees are typically charged on 'token in', but there is no 'token in' here, so we apply it to
                // 'token out'. This results in slightly larger price impact.

                uint256 amountOutWithFee;
                if (invariantRatioWithoutFees > balanceRatiosWithoutFee[i]) {
                    uint256 nonTaxableAmount =
                        balances[i].mulDown(invariantRatioWithoutFees.complement());
                    uint256 taxableAmount = amountsOut[i].sub(nonTaxableAmount);
                    uint256 taxableAmountPlusFees =
                        taxableAmount.divUp(swapFeePercentage.complement());

                    amountOutWithFee = nonTaxableAmount.add(taxableAmountPlusFees);
                } else {
                    amountOutWithFee = amountsOut[i];
                    // If a token's amount out is not being charged a swap fee then it might be zero (e.g. when exiting a
                    // Pool with only a subset of tokens). In this case, `balanceRatio` will equal `FixedPoint.ONE`, and
                    // the `invariantRatio` will not change at all. We therefore skip to the next iteration, avoiding
                    // the costly `powDown` call.
                    if (amountOutWithFee == 0) {
                        continue;
                    }
                }

                uint256 balanceRatio = balances[i].sub(amountOutWithFee).divDown(balances[i]);

                invariantRatio = invariantRatio.mulDown(balanceRatio.powDown(normalizedWeights[i]));
            }
        }
    }

    function _calcTokenOutGivenExactBptIn(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 bptAmountIn,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        /**
         *
         *     // exactBPTInForTokenOut                                                                //
         *     // a = amountOut                                                                        //
         *     // b = balance                     /      /    totalBPT - bptIn       \    (1 / w)  \   //
         *     // bptIn = bptAmountIn    a = b * |  1 - | --------------------------  | ^           |  //
         *     // bpt = totalBPT                  \      \       totalBPT            /             /   //
         *     // w = weight                                                                           //
         *
         */

        // Token out, so we round down overall. The multiplication rounds down, but the power rounds up (so the base
        // rounds up). Because (totalBPT - bptIn) / totalBPT <= 1, the exponent rounds down.

        // Calculate the factor by which the invariant will decrease after burning BPTAmountIn
        uint256 invariantRatio = bptTotalSupply.sub(bptAmountIn).divUp(bptTotalSupply);
        _require(invariantRatio >= _MIN_INVARIANT_RATIO, Errors.MIN_BPT_IN_FOR_TOKEN_OUT);

        // Calculate by how much the token balance has to decrease to match invariantRatio
        uint256 balanceRatio = invariantRatio.powUp(FixedPoint.ONE.divDown(normalizedWeight));

        // Because of rounding up, balanceRatio can be greater than one. Using complement prevents reverts.
        uint256 amountOutWithoutFee = balance.mulDown(balanceRatio.complement());

        // We can now compute how much excess balance is being withdrawn as a result of the virtual swaps, which result
        // in swap fees.

        // Swap fees are typically charged on 'token in', but there is no 'token in' here, so we apply it
        // to 'token out'. This results in slightly larger price impact. Fees are rounded up.
        uint256 taxableAmount = amountOutWithoutFee.mulUp(normalizedWeight.complement());
        uint256 nonTaxableAmount = amountOutWithoutFee.sub(taxableAmount);
        uint256 taxableAmountMinusFees = taxableAmount.mulUp(swapFeePercentage.complement());

        return nonTaxableAmount.add(taxableAmountMinusFees);
    }

    /**
     * @dev Calculate the amount of BPT which should be minted when adding a new token to the Pool.
     *
     * Note that normalizedWeight is set that it corresponds to the desired weight of this token *after* adding it.
     * i.e. For a two token 50:50 pool which we want to turn into a 33:33:33 pool, we use a normalized weight of 33%
     * @param totalSupply - the total supply of the Pool's BPT.
     * @param normalizedWeight - the normalized weight of the token to be added (normalized relative to final weights)
     */
    function _calcBptOutAddToken(uint256 totalSupply, uint256 normalizedWeight)
        internal
        pure
        returns (uint256)
    {
        // The amount of BPT which is equivalent to the token being added may be calculated by the growth in the
        // sum of the token weights, i.e. if we add a token which will make up 50% of the pool then we should receive
        // 50% of the new supply of BPT.
        //
        // The growth in the total weight of the pool can be easily calculated by:
        //
        // weightSumRatio = totalWeight / (totalWeight - newTokenWeight)
        //
        // As we're working with normalized weights `totalWeight` is equal to 1.

        uint256 weightSumRatio = FixedPoint.ONE.divDown(FixedPoint.ONE.sub(normalizedWeight));

        // The amount of BPT to mint is then simply:
        //
        // toMint = totalSupply * (weightSumRatio - 1)

        return totalSupply.mulDown(weightSumRatio.sub(FixedPoint.ONE));
    }
}

/**
 * @dev Reverts if `condition` is false, with a revert reason containing `errorCode`. Only codes up to 999 are
 * supported.
 * Uses the default 'BAL' prefix for the error code
 */
function _require(bool condition, uint256 errorCode) pure {
    if (!condition) _revert(errorCode);
}

/**
 * @dev Reverts if `condition` is false, with a revert reason containing `errorCode`. Only codes up to 999 are
 * supported.
 */
function _require(bool condition, uint256 errorCode, bytes3 prefix) pure {
    if (!condition) _revert(errorCode, prefix);
}

/**
 * @dev Reverts with a revert reason containing `errorCode`. Only codes up to 999 are supported.
 * Uses the default 'BAL' prefix for the error code
 */
function _revert(uint256 errorCode) pure {
    _revert(errorCode, 0x42414c); // This is the raw byte representation of "BAL"
}

/**
 * @dev Reverts with a revert reason containing `errorCode`. Only codes up to 999 are supported.
 */
function _revert(uint256 errorCode, bytes3 prefix) pure {
    uint256 prefixUint = uint256(uint24(prefix));
    // We're going to dynamically create a revert string based on the error code, with the following format:
    // 'BAL#{errorCode}'
    // where the code is left-padded with zeroes to three digits (so they range from 000 to 999).
    //
    // We don't have revert strings embedded in the contract to save bytecode size: it takes much less space to store a
    // number (8 to 16 bits) than the individual string characters.
    //
    // The dynamic string creation algorithm that follows could be implemented in Solidity, but assembly allows for a
    // much denser implementation, again saving bytecode size. Given this function unconditionally reverts, this is a
    // safe place to rely on it without worrying about how its usage might affect e.g. memory contents.
    assembly {
        // First, we need to compute the ASCII representation of the error code. We assume that it is in the 0-999
        // range, so we only need to convert three digits. To convert the digits to ASCII, we add 0x30, the value for
        // the '0' character.

        let units := add(mod(errorCode, 10), 0x30)

        errorCode := div(errorCode, 10)
        let tenths := add(mod(errorCode, 10), 0x30)

        errorCode := div(errorCode, 10)
        let hundreds := add(mod(errorCode, 10), 0x30)

        // With the individual characters, we can now construct the full string.
        // We first append the '#' character (0x23) to the prefix. In the case of 'BAL', it results in 0x42414c23 ('BAL#')
        // Then, we shift this by 24 (to provide space for the 3 bytes of the error code), and add the
        // characters to it, each shifted by a multiple of 8.
        // The revert reason is then shifted left by 200 bits (256 minus the length of the string, 7 characters * 8 bits
        // per character = 56) to locate it in the most significant part of the 256 slot (the beginning of a byte
        // array).
        let formattedPrefix := shl(24, add(0x23, shl(8, prefixUint)))

        let revertReason :=
            shl(200, add(formattedPrefix, add(add(units, shl(8, tenths)), shl(16, hundreds))))

        // We can now encode the reason in memory, which can be safely overwritten as we're about to revert. The encoded
        // message will have the following layout:
        // [ revert reason identifier ] [ string location offset ] [ string length ] [ string contents ]

        // The Solidity revert reason identifier is 0x08c739a0, the function selector of the Error(string) function. We
        // also write zeroes to the next 28 bytes of memory, but those are about to be overwritten.
        mstore(0x0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
        // Next is the offset to the location of the string, which will be placed immediately after (20 bytes away).
        mstore(0x04, 0x0000000000000000000000000000000000000000000000000000000000000020)
        // The string length is fixed: 7 characters.
        mstore(0x24, 7)
        // Finally, the string itself is stored.
        mstore(0x44, revertReason)

        // Even if the string is only 7 bytes long, we need to return a full 32 byte slot containing it. The length of
        // the encoded message is therefore 4 + 32 + 32 + 32 = 100.
        revert(0, 100)
    }
}

library Errors {
    // Math
    uint256 internal constant ADD_OVERFLOW = 0;
    uint256 internal constant SUB_OVERFLOW = 1;
    uint256 internal constant SUB_UNDERFLOW = 2;
    uint256 internal constant MUL_OVERFLOW = 3;
    uint256 internal constant ZERO_DIVISION = 4;
    uint256 internal constant DIV_INTERNAL = 5;
    uint256 internal constant X_OUT_OF_BOUNDS = 6;
    uint256 internal constant Y_OUT_OF_BOUNDS = 7;
    uint256 internal constant PRODUCT_OUT_OF_BOUNDS = 8;
    uint256 internal constant INVALID_EXPONENT = 9;

    // Input
    uint256 internal constant OUT_OF_BOUNDS = 100;
    uint256 internal constant UNSORTED_ARRAY = 101;
    uint256 internal constant UNSORTED_TOKENS = 102;
    uint256 internal constant INPUT_LENGTH_MISMATCH = 103;
    uint256 internal constant ZERO_TOKEN = 104;
    uint256 internal constant INSUFFICIENT_DATA = 105;

    // Shared pools
    uint256 internal constant MIN_TOKENS = 200;
    uint256 internal constant MAX_TOKENS = 201;
    uint256 internal constant MAX_SWAP_FEE_PERCENTAGE = 202;
    uint256 internal constant MIN_SWAP_FEE_PERCENTAGE = 203;
    uint256 internal constant MINIMUM_BPT = 204;
    uint256 internal constant CALLER_NOT_VAULT = 205;
    uint256 internal constant UNINITIALIZED = 206;
    uint256 internal constant BPT_IN_MAX_AMOUNT = 207;
    uint256 internal constant BPT_OUT_MIN_AMOUNT = 208;
    uint256 internal constant EXPIRED_PERMIT = 209;
    uint256 internal constant NOT_TWO_TOKENS = 210;
    uint256 internal constant DISABLED = 211;

    // Pools
    uint256 internal constant MIN_AMP = 300;
    uint256 internal constant MAX_AMP = 301;
    uint256 internal constant MIN_WEIGHT = 302;
    uint256 internal constant MAX_STABLE_TOKENS = 303;
    uint256 internal constant MAX_IN_RATIO = 304;
    uint256 internal constant MAX_OUT_RATIO = 305;
    uint256 internal constant MIN_BPT_IN_FOR_TOKEN_OUT = 306;
    uint256 internal constant MAX_OUT_BPT_FOR_TOKEN_IN = 307;
    uint256 internal constant NORMALIZED_WEIGHT_INVARIANT = 308;
    uint256 internal constant INVALID_TOKEN = 309;
    uint256 internal constant UNHANDLED_JOIN_KIND = 310;
    uint256 internal constant ZERO_INVARIANT = 311;
    uint256 internal constant ORACLE_INVALID_SECONDS_QUERY = 312;
    uint256 internal constant ORACLE_NOT_INITIALIZED = 313;
    uint256 internal constant ORACLE_QUERY_TOO_OLD = 314;
    uint256 internal constant ORACLE_INVALID_INDEX = 315;
    uint256 internal constant ORACLE_BAD_SECS = 316;
    uint256 internal constant AMP_END_TIME_TOO_CLOSE = 317;
    uint256 internal constant AMP_ONGOING_UPDATE = 318;
    uint256 internal constant AMP_RATE_TOO_HIGH = 319;
    uint256 internal constant AMP_NO_ONGOING_UPDATE = 320;
    uint256 internal constant STABLE_INVARIANT_DIDNT_CONVERGE = 321;
    uint256 internal constant STABLE_GET_BALANCE_DIDNT_CONVERGE = 322;
    uint256 internal constant RELAYER_NOT_CONTRACT = 323;
    uint256 internal constant BASE_POOL_RELAYER_NOT_CALLED = 324;
    uint256 internal constant REBALANCING_RELAYER_REENTERED = 325;
    uint256 internal constant GRADUAL_UPDATE_TIME_TRAVEL = 326;
    uint256 internal constant SWAPS_DISABLED = 327;
    uint256 internal constant CALLER_IS_NOT_LBP_OWNER = 328;
    uint256 internal constant PRICE_RATE_OVERFLOW = 329;
    uint256 internal constant INVALID_JOIN_EXIT_KIND_WHILE_SWAPS_DISABLED = 330;
    uint256 internal constant WEIGHT_CHANGE_TOO_FAST = 331;
    uint256 internal constant LOWER_GREATER_THAN_UPPER_TARGET = 332;
    uint256 internal constant UPPER_TARGET_TOO_HIGH = 333;
    uint256 internal constant UNHANDLED_BY_LINEAR_POOL = 334;
    uint256 internal constant OUT_OF_TARGET_RANGE = 335;
    uint256 internal constant UNHANDLED_EXIT_KIND = 336;
    uint256 internal constant UNAUTHORIZED_EXIT = 337;
    uint256 internal constant MAX_MANAGEMENT_SWAP_FEE_PERCENTAGE = 338;
    uint256 internal constant UNHANDLED_BY_MANAGED_POOL = 339;
    uint256 internal constant UNHANDLED_BY_PHANTOM_POOL = 340;
    uint256 internal constant TOKEN_DOES_NOT_HAVE_RATE_PROVIDER = 341;
    uint256 internal constant INVALID_INITIALIZATION = 342;
    uint256 internal constant OUT_OF_NEW_TARGET_RANGE = 343;
    uint256 internal constant FEATURE_DISABLED = 344;
    uint256 internal constant UNINITIALIZED_POOL_CONTROLLER = 345;
    uint256 internal constant SET_SWAP_FEE_DURING_FEE_CHANGE = 346;
    uint256 internal constant SET_SWAP_FEE_PENDING_FEE_CHANGE = 347;
    uint256 internal constant CHANGE_TOKENS_DURING_WEIGHT_CHANGE = 348;
    uint256 internal constant CHANGE_TOKENS_PENDING_WEIGHT_CHANGE = 349;
    uint256 internal constant MAX_WEIGHT = 350;
    uint256 internal constant UNAUTHORIZED_JOIN = 351;
    uint256 internal constant MAX_MANAGEMENT_AUM_FEE_PERCENTAGE = 352;
    uint256 internal constant FRACTIONAL_TARGET = 353;
    uint256 internal constant ADD_OR_REMOVE_BPT = 354;
    uint256 internal constant INVALID_CIRCUIT_BREAKER_BOUNDS = 355;
    uint256 internal constant CIRCUIT_BREAKER_TRIPPED = 356;
    uint256 internal constant MALICIOUS_QUERY_REVERT = 357;
    uint256 internal constant JOINS_EXITS_DISABLED = 358;

    // Lib
    uint256 internal constant REENTRANCY = 400;
    uint256 internal constant SENDER_NOT_ALLOWED = 401;
    uint256 internal constant PAUSED = 402;
    uint256 internal constant PAUSE_WINDOW_EXPIRED = 403;
    uint256 internal constant MAX_PAUSE_WINDOW_DURATION = 404;
    uint256 internal constant MAX_BUFFER_PERIOD_DURATION = 405;
    uint256 internal constant INSUFFICIENT_BALANCE = 406;
    uint256 internal constant INSUFFICIENT_ALLOWANCE = 407;
    uint256 internal constant ERC20_TRANSFER_FROM_ZERO_ADDRESS = 408;
    uint256 internal constant ERC20_TRANSFER_TO_ZERO_ADDRESS = 409;
    uint256 internal constant ERC20_MINT_TO_ZERO_ADDRESS = 410;
    uint256 internal constant ERC20_BURN_FROM_ZERO_ADDRESS = 411;
    uint256 internal constant ERC20_APPROVE_FROM_ZERO_ADDRESS = 412;
    uint256 internal constant ERC20_APPROVE_TO_ZERO_ADDRESS = 413;
    uint256 internal constant ERC20_TRANSFER_EXCEEDS_ALLOWANCE = 414;
    uint256 internal constant ERC20_DECREASED_ALLOWANCE_BELOW_ZERO = 415;
    uint256 internal constant ERC20_TRANSFER_EXCEEDS_BALANCE = 416;
    uint256 internal constant ERC20_BURN_EXCEEDS_ALLOWANCE = 417;
    uint256 internal constant SAFE_ERC20_CALL_FAILED = 418;
    uint256 internal constant ADDRESS_INSUFFICIENT_BALANCE = 419;
    uint256 internal constant ADDRESS_CANNOT_SEND_VALUE = 420;
    uint256 internal constant SAFE_CAST_VALUE_CANT_FIT_INT256 = 421;
    uint256 internal constant GRANT_SENDER_NOT_ADMIN = 422;
    uint256 internal constant REVOKE_SENDER_NOT_ADMIN = 423;
    uint256 internal constant RENOUNCE_SENDER_NOT_ALLOWED = 424;
    uint256 internal constant BUFFER_PERIOD_EXPIRED = 425;
    uint256 internal constant CALLER_IS_NOT_OWNER = 426;
    uint256 internal constant NEW_OWNER_IS_ZERO = 427;
    uint256 internal constant CODE_DEPLOYMENT_FAILED = 428;
    uint256 internal constant CALL_TO_NON_CONTRACT = 429;
    uint256 internal constant LOW_LEVEL_CALL_FAILED = 430;
    uint256 internal constant NOT_PAUSED = 431;
    uint256 internal constant ADDRESS_ALREADY_ALLOWLISTED = 432;
    uint256 internal constant ADDRESS_NOT_ALLOWLISTED = 433;
    uint256 internal constant ERC20_BURN_EXCEEDS_BALANCE = 434;
    uint256 internal constant INVALID_OPERATION = 435;
    uint256 internal constant CODEC_OVERFLOW = 436;
    uint256 internal constant IN_RECOVERY_MODE = 437;
    uint256 internal constant NOT_IN_RECOVERY_MODE = 438;
    uint256 internal constant INDUCED_FAILURE = 439;
    uint256 internal constant EXPIRED_SIGNATURE = 440;
    uint256 internal constant MALFORMED_SIGNATURE = 441;
    uint256 internal constant SAFE_CAST_VALUE_CANT_FIT_UINT64 = 442;
    uint256 internal constant UNHANDLED_FEE_TYPE = 443;
    uint256 internal constant BURN_FROM_ZERO = 444;

    // Vault
    uint256 internal constant INVALID_POOL_ID = 500;
    uint256 internal constant CALLER_NOT_POOL = 501;
    uint256 internal constant SENDER_NOT_ASSET_MANAGER = 502;
    uint256 internal constant USER_DOESNT_ALLOW_RELAYER = 503;
    uint256 internal constant INVALID_SIGNATURE = 504;
    uint256 internal constant EXIT_BELOW_MIN = 505;
    uint256 internal constant JOIN_ABOVE_MAX = 506;
    uint256 internal constant SWAP_LIMIT = 507;
    uint256 internal constant SWAP_DEADLINE = 508;
    uint256 internal constant CANNOT_SWAP_SAME_TOKEN = 509;
    uint256 internal constant UNKNOWN_AMOUNT_IN_FIRST_SWAP = 510;
    uint256 internal constant MALCONSTRUCTED_MULTIHOP_SWAP = 511;
    uint256 internal constant INTERNAL_BALANCE_OVERFLOW = 512;
    uint256 internal constant INSUFFICIENT_INTERNAL_BALANCE = 513;
    uint256 internal constant INVALID_ETH_INTERNAL_BALANCE = 514;
    uint256 internal constant INVALID_POST_LOAN_BALANCE = 515;
    uint256 internal constant INSUFFICIENT_ETH = 516;
    uint256 internal constant UNALLOCATED_ETH = 517;
    uint256 internal constant ETH_TRANSFER = 518;
    uint256 internal constant CANNOT_USE_ETH_SENTINEL = 519;
    uint256 internal constant TOKENS_MISMATCH = 520;
    uint256 internal constant TOKEN_NOT_REGISTERED = 521;
    uint256 internal constant TOKEN_ALREADY_REGISTERED = 522;
    uint256 internal constant TOKENS_ALREADY_SET = 523;
    uint256 internal constant TOKENS_LENGTH_MUST_BE_2 = 524;
    uint256 internal constant NONZERO_TOKEN_BALANCE = 525;
    uint256 internal constant BALANCE_TOTAL_OVERFLOW = 526;
    uint256 internal constant POOL_NO_TOKENS = 527;
    uint256 internal constant INSUFFICIENT_FLASH_LOAN_BALANCE = 528;

    // Fees
    uint256 internal constant SWAP_FEE_PERCENTAGE_TOO_HIGH = 600;
    uint256 internal constant FLASH_LOAN_FEE_PERCENTAGE_TOO_HIGH = 601;
    uint256 internal constant INSUFFICIENT_FLASH_LOAN_FEE_AMOUNT = 602;
    uint256 internal constant AUM_FEE_PERCENTAGE_TOO_HIGH = 603;

    // FeeSplitter
    uint256 internal constant SPLITTER_FEE_PERCENTAGE_TOO_HIGH = 700;

    // Misc
    uint256 internal constant UNIMPLEMENTED = 998;
    uint256 internal constant SHOULD_NOT_HAPPEN = 999;
}

library FixedPoint {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant TWO = 2 * ONE;
    uint256 internal constant FOUR = 4 * ONE;
    uint256 internal constant MAX_POW_RELATIVE_ERROR = 10000;
    uint256 internal constant MIN_POW_BASE_FREE_EXPONENT = 0.7e18;

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            uint256 c = a + b;
            _require(c >= a, Errors.ADD_OVERFLOW);
            return c;
        }
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            _require(b <= a, Errors.SUB_OVERFLOW);
            uint256 c = a - b;
            return c;
        }
    }

    function mulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            uint256 product = a * b;
            _require(a == 0 || product / a == b, Errors.MUL_OVERFLOW);
            return product / ONE;
        }
    }

    function mulUp(uint256 a, uint256 b) internal pure returns (uint256 result) {
        unchecked {
            uint256 product = a * b;
            _require(a == 0 || product / a == b, Errors.MUL_OVERFLOW);
            assembly {
                result := mul(iszero(iszero(product)), add(div(sub(product, 1), ONE), 1))
            }
        }
    }

    function divDown(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            _require(b != 0, Errors.ZERO_DIVISION);
            uint256 aInflated = a * ONE;
            _require(a == 0 || aInflated / a == ONE, Errors.DIV_INTERNAL);
            return aInflated / b;
        }
    }

    function divUp(uint256 a, uint256 b) internal pure returns (uint256 result) {
        unchecked {
            _require(b != 0, Errors.ZERO_DIVISION);
            uint256 aInflated = a * ONE;
            _require(a == 0 || aInflated / a == ONE, Errors.DIV_INTERNAL);
            assembly {
                result := mul(iszero(iszero(aInflated)), add(div(sub(aInflated, 1), b), 1))
            }
        }
    }

    function powDown(uint256 x, uint256 y) internal pure returns (uint256) {
        unchecked {
            if (y == ONE) {
                return x;
            } else if (y == TWO) {
                return mulDown(x, x);
            } else if (y == FOUR) {
                uint256 square = mulDown(x, x);
                return mulDown(square, square);
            } else {
                uint256 raw = LogExpMath.pow(x, y);
                uint256 maxError = add(mulUp(raw, MAX_POW_RELATIVE_ERROR), 1);

                if (raw < maxError) {
                    return 0;
                } else {
                    return sub(raw, maxError);
                }
            }
        }
    }

    function powUp(uint256 x, uint256 y) internal pure returns (uint256) {
        unchecked {
            if (y == ONE) {
                return x;
            } else if (y == TWO) {
                return mulUp(x, x);
            } else if (y == FOUR) {
                uint256 square = mulUp(x, x);
                return mulUp(square, square);
            } else {
                uint256 raw = LogExpMath.pow(x, y);
                uint256 maxError = add(mulUp(raw, MAX_POW_RELATIVE_ERROR), 1);

                return add(raw, maxError);
            }
        }
    }

    function complement(uint256 x) internal pure returns (uint256 result) {
        assembly {
            result := mul(lt(x, ONE), sub(ONE, x))
        }
    }
}

library Math {
    function abs(int256 a) internal pure returns (uint256 result) {
        assembly {
            let s := sar(255, a)
            result := sub(xor(a, s), s)
        }
    }

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            uint256 c = a + b;
            _require(c >= a, Errors.ADD_OVERFLOW);
            return c;
        }
    }

    function add(int256 a, int256 b) internal pure returns (int256) {
        unchecked {
            int256 c = a + b;
            _require((b >= 0 && c >= a) || (b < 0 && c < a), Errors.ADD_OVERFLOW);
            return c;
        }
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            _require(b <= a, Errors.SUB_OVERFLOW);
            uint256 c = a - b;
            return c;
        }
    }

    function sub(int256 a, int256 b) internal pure returns (int256) {
        unchecked {
            int256 c = a - b;
            _require((b >= 0 && c <= a) || (b < 0 && c > a), Errors.SUB_OVERFLOW);
            return c;
        }
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256 result) {
        assembly {
            result := sub(a, mul(sub(a, b), lt(a, b)))
        }
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256 result) {
        assembly {
            result := sub(a, mul(sub(a, b), gt(a, b)))
        }
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            uint256 c = a * b;
            _require(a == 0 || c / a == b, Errors.MUL_OVERFLOW);
            return c;
        }
    }

    function div(uint256 a, uint256 b, bool roundUp) internal pure returns (uint256) {
        unchecked {
            return roundUp ? divUp(a, b) : divDown(a, b);
        }
    }

    function divDown(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            _require(b != 0, Errors.ZERO_DIVISION);
            return a / b;
        }
    }

    function divUp(uint256 a, uint256 b) internal pure returns (uint256 result) {
        unchecked {
            _require(b != 0, Errors.ZERO_DIVISION);
            assembly {
                result := mul(iszero(iszero(a)), add(1, div(sub(a, 1), b)))
            }
        }
    }
}

library LogExpMath {
    int256 constant ONE_18 = 1e18;
    int256 constant ONE_20 = 1e20;
    int256 constant ONE_36 = 1e36;
    int256 constant MAX_NATURAL_EXPONENT = 130e18;
    int256 constant MIN_NATURAL_EXPONENT = -41e18;
    int256 constant LN_36_LOWER_BOUND = ONE_18 - 1e17;
    int256 constant LN_36_UPPER_BOUND = ONE_18 + 1e17;
    uint256 constant MILD_EXPONENT_BOUND = 2 ** 254 / uint256(ONE_20);
    int256 constant x0 = 128000000000000000000;
    int256 constant a0 = 38877084059945950922200000000000000000000000000000000000;
    int256 constant x1 = 64000000000000000000;
    int256 constant a1 = 6235149080811616882910000000;
    int256 constant x2 = 3200000000000000000000;
    int256 constant a2 = 7896296018268069516100000000000000;
    int256 constant x3 = 1600000000000000000000;
    int256 constant a3 = 888611052050787263676000000;
    int256 constant x4 = 800000000000000000000;
    int256 constant a4 = 298095798704172827474000;
    int256 constant x5 = 400000000000000000000;
    int256 constant a5 = 5459815003314423907810;
    int256 constant x6 = 200000000000000000000;
    int256 constant a6 = 738905609893065022723;
    int256 constant x7 = 100000000000000000000;
    int256 constant a7 = 271828182845904523536;
    int256 constant x8 = 50000000000000000000;
    int256 constant a8 = 164872127070012814685;
    int256 constant x9 = 25000000000000000000;
    int256 constant a9 = 128402541668774148407;
    int256 constant x10 = 12500000000000000000;
    int256 constant a10 = 113314845306682631683;
    int256 constant x11 = 6250000000000000000;
    int256 constant a11 = 106449445891785942956;

    function pow(uint256 x, uint256 y) internal pure returns (uint256) {
        unchecked {
            if (y == 0) {
                return uint256(ONE_18);
            }
            if (x == 0) {
                return 0;
            }
            _require(x >> 255 == 0, Errors.X_OUT_OF_BOUNDS);
            int256 x_int256 = int256(x);
            _require(y < MILD_EXPONENT_BOUND, Errors.Y_OUT_OF_BOUNDS);
            int256 y_int256 = int256(y);
            int256 logx_times_y;
            if (LN_36_LOWER_BOUND < x_int256 && x_int256 < LN_36_UPPER_BOUND) {
                int256 ln_36_x = _ln_36(x_int256);
                logx_times_y =
                    ((ln_36_x / ONE_18) * y_int256 + ((ln_36_x % ONE_18) * y_int256) / ONE_18);
            } else {
                logx_times_y = _ln(x_int256) * y_int256;
            }
            logx_times_y /= ONE_18;
            _require(
                MIN_NATURAL_EXPONENT <= logx_times_y && logx_times_y <= MAX_NATURAL_EXPONENT,
                Errors.PRODUCT_OUT_OF_BOUNDS
            );
            return uint256(exp(logx_times_y));
        }
    }

    function exp(int256 x) internal pure returns (int256) {
        unchecked {
            _require(
                x >= MIN_NATURAL_EXPONENT && x <= MAX_NATURAL_EXPONENT, Errors.INVALID_EXPONENT
            );
            if (x < 0) {
                return ((ONE_18 * ONE_18) / exp(-x));
            }
            int256 firstAN;
            if (x >= x0) {
                x -= x0;
                firstAN = a0;
            } else if (x >= x1) {
                x -= x1;
                firstAN = a1;
            } else {
                firstAN = 1;
            }
            x *= 100;
            int256 product = ONE_20;
            if (x >= x2) {
                x -= x2;
                product = (product * a2) / ONE_20;
            }
            if (x >= x3) {
                x -= x3;
                product = (product * a3) / ONE_20;
            }
            if (x >= x4) {
                x -= x4;
                product = (product * a4) / ONE_20;
            }
            if (x >= x5) {
                x -= x5;
                product = (product * a5) / ONE_20;
            }
            if (x >= x6) {
                x -= x6;
                product = (product * a6) / ONE_20;
            }
            if (x >= x7) {
                x -= x7;
                product = (product * a7) / ONE_20;
            }
            if (x >= x8) {
                x -= x8;
                product = (product * a8) / ONE_20;
            }
            if (x >= x9) {
                x -= x9;
                product = (product * a9) / ONE_20;
            }
            int256 seriesSum = ONE_20;
            int256 term;
            term = x;
            seriesSum += term;
            term = ((term * x) / ONE_20) / 2;
            seriesSum += term;
            term = ((term * x) / ONE_20) / 3;
            seriesSum += term;
            term = ((term * x) / ONE_20) / 4;
            seriesSum += term;
            term = ((term * x) / ONE_20) / 5;
            seriesSum += term;
            term = ((term * x) / ONE_20) / 6;
            seriesSum += term;
            term = ((term * x) / ONE_20) / 7;
            seriesSum += term;
            term = ((term * x) / ONE_20) / 8;
            seriesSum += term;
            term = ((term * x) / ONE_20) / 9;
            seriesSum += term;
            term = ((term * x) / ONE_20) / 10;
            seriesSum += term;
            term = ((term * x) / ONE_20) / 11;
            seriesSum += term;
            term = ((term * x) / ONE_20) / 12;
            seriesSum += term;
            return (((product * seriesSum) / ONE_20) * firstAN) / 100;
        }
    }

    function log(int256 arg, int256 base) internal pure returns (int256) {
        unchecked {
            int256 logBase;
            if (LN_36_LOWER_BOUND < base && base < LN_36_UPPER_BOUND) {
                logBase = _ln_36(base);
            } else {
                logBase = _ln(base) * ONE_18;
            }
            int256 logArg;
            if (LN_36_LOWER_BOUND < arg && arg < LN_36_UPPER_BOUND) {
                logArg = _ln_36(arg);
            } else {
                logArg = _ln(arg) * ONE_18;
            }
            return (logArg * ONE_18) / logBase;
        }
    }

    function ln(int256 a) internal pure returns (int256) {
        unchecked {
            _require(a > 0, Errors.OUT_OF_BOUNDS);
            if (LN_36_LOWER_BOUND < a && a < LN_36_UPPER_BOUND) {
                return _ln_36(a) / ONE_18;
            } else {
                return _ln(a);
            }
        }
    }

    function _ln(int256 a) private pure returns (int256) {
        unchecked {
            if (a < ONE_18) {
                return (-_ln((ONE_18 * ONE_18) / a));
            }
            int256 sum = 0;
            if (a >= a0 * ONE_18) {
                a /= a0;
                sum += x0;
            }
            if (a >= a1 * ONE_18) {
                a /= a1;
                sum += x1;
            }
            sum *= 100;
            a *= 100;
            if (a >= a2) {
                a = (a * ONE_20) / a2;
                sum += x2;
            }
            if (a >= a3) {
                a = (a * ONE_20) / a3;
                sum += x3;
            }
            if (a >= a4) {
                a = (a * ONE_20) / a4;
                sum += x4;
            }
            if (a >= a5) {
                a = (a * ONE_20) / a5;
                sum += x5;
            }
            if (a >= a6) {
                a = (a * ONE_20) / a6;
                sum += x6;
            }
            if (a >= a7) {
                a = (a * ONE_20) / a7;
                sum += x7;
            }
            if (a >= a8) {
                a = (a * ONE_20) / a8;
                sum += x8;
            }
            if (a >= a9) {
                a = (a * ONE_20) / a9;
                sum += x9;
            }
            if (a >= a10) {
                a = (a * ONE_20) / a10;
                sum += x10;
            }
            if (a >= a11) {
                a = (a * ONE_20) / a11;
                sum += x11;
            }
            int256 z = ((a - ONE_20) * ONE_20) / (a + ONE_20);
            int256 z_squared = (z * z) / ONE_20;
            int256 num = z;
            int256 seriesSum = num;
            num = (num * z_squared) / ONE_20;
            seriesSum += num / 3;
            num = (num * z_squared) / ONE_20;
            seriesSum += num / 5;
            num = (num * z_squared) / ONE_20;
            seriesSum += num / 7;
            num = (num * z_squared) / ONE_20;
            seriesSum += num / 9;
            num = (num * z_squared) / ONE_20;
            seriesSum += num / 11;
            seriesSum *= 2;
            return (sum + seriesSum) / 100;
        }
    }

    function _ln_36(int256 x) private pure returns (int256) {
        unchecked {
            x *= ONE_18;
            int256 z = ((x - ONE_36) * ONE_36) / (x + ONE_36);
            int256 z_squared = (z * z) / ONE_36;
            int256 num = z;
            int256 seriesSum = num;
            num = (num * z_squared) / ONE_36;
            seriesSum += num / 3;
            num = (num * z_squared) / ONE_36;
            seriesSum += num / 5;
            num = (num * z_squared) / ONE_36;
            seriesSum += num / 7;
            num = (num * z_squared) / ONE_36;
            seriesSum += num / 9;
            num = (num * z_squared) / ONE_36;
            seriesSum += num / 11;
            num = (num * z_squared) / ONE_36;
            seriesSum += num / 13;
            num = (num * z_squared) / ONE_36;
            seriesSum += num / 15;
            return seriesSum * 2;
        }
    }
}
