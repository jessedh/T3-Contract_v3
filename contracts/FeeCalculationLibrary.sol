// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FeeCalculationLibrary
 * @dev A library for pure and view functions related to fee calculations.
 * This helps reduce the main contract's bytecode size.
 */
library FeeCalculationLibrary {
    // Constants from T3Token, duplicated here for library's pure/view functions.
    // Ensure these constants are kept in sync with T3Token if they change.
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant FEE_PRECISION_MULTIPLIER = 1000;
    uint256 private constant EFFECTIVE_BASIS_POINTS = BASIS_POINTS * FEE_PRECISION_MULTIPLIER;
    uint256 private constant TIER_MULTIPLIER = 10;
    uint256 private constant MAX_RISK_SCALER_BPS = BASIS_POINTS; // 100% max scaler
    uint256 private constant BASE_RISK_SCALER_BPS = 1; // 0.01% per tier base

    // Define a struct for a single tier entry to improve type clarity and potentially compiler handling
    struct TierEntry {
        uint256 ceiling;
        uint256 rate;
    }

    /**
     * @dev Calculates the base fee amount based on a tiered structure.
     * @param amount The amount for which to calculate the base fee.
     * @return The calculated base fee amount.
     */
    function calculateBaseFeeAmount(uint256 amount) internal pure returns (uint256) {
        if (amount == 0) return 0;
        uint256 totalFee = 0;

        // Use an array of TierEntry structs for the tiers
        TierEntry[10] memory tiers;
        tiers[0] = TierEntry({ceiling: 1e16, rate: 100000 * FEE_PRECISION_MULTIPLIER}); // 0.01 ether
        tiers[1] = TierEntry({ceiling: 1e17, rate: 10000 * FEE_PRECISION_MULTIPLIER});  // 0.10 ether
        tiers[2] = TierEntry({ceiling: 1e18, rate: 1000 * FEE_PRECISION_MULTIPLIER});   // 1.00 ether
        tiers[3] = TierEntry({ceiling: 1e19, rate: 100 * FEE_PRECISION_MULTIPLIER});    // 10.0 ether
        tiers[4] = TierEntry({ceiling: 1e20, rate: 10 * FEE_PRECISION_MULTIPLIER});     // 100.0 ether
        tiers[5] = TierEntry({ceiling: 1e21, rate: 1 * FEE_PRECISION_MULTIPLIER});      // 1000.0 ether
        tiers[6] = TierEntry({ceiling: 1e22, rate: (1 * FEE_PRECISION_MULTIPLIER) / 10});   // 10000.0 ether
        tiers[7] = TierEntry({ceiling: 1e23, rate: (1 * FEE_PRECISION_MULTIPLIER) / 100});  // 100000.0 ether
        tiers[8] = TierEntry({ceiling: 1e24, rate: (1 * FEE_PRECISION_MULTIPLIER) / 1000}); // 1000000.0 ether
        tiers[9] = TierEntry({ceiling: type(uint256).max, rate: (1 * FEE_PRECISION_MULTIPLIER) / 10000});


        for (uint i = 0; i < tiers.length; i++) {
            uint256 tierCeiling = tiers[i].ceiling;
            uint256 scaledTierRateBps = tiers[i].rate;
            uint256 tierFloor = (i == 0) ? 0 : tiers[i-1].ceiling; // Access ceiling from previous tier
            uint256 amountInTier = 0;

            if (amount > tierFloor) {
                if (amount >= tierCeiling) {
                    if (tierCeiling > tierFloor) {
                        amountInTier = tierCeiling - tierFloor;
                    } else {
                        amountInTier = 0;
                        if (tierCeiling == type(uint256).max) break;
                    }
                } else {
                    amountInTier = amount - tierFloor;
                }
            }

            if (amountInTier > 0) {
                 totalFee += (amountInTier * scaledTierRateBps) / EFFECTIVE_BASIS_POINTS;
            }

            if (amount < tierCeiling || tierCeiling == type(uint256).max) break;
        }
        return totalFee;
    }

    /**
     * @dev Calculates a risk scaler based on the amount, using token decimals for tiering.
     * @param amount The amount for which to calculate the risk scaler.
     * @param _tokenDecimals The number of decimals of the token.
     * @return The calculated amount risk scaler in basis points.
     */
    function calculateAmountRiskScaler(uint256 amount, uint256 _tokenDecimals) internal pure returns (uint256) {
        if (amount == 0) return 0;
        uint256 tierCeiling = 1 * (10**_tokenDecimals);
        uint256 currentScalerBps = BASE_RISK_SCALER_BPS;

        while (amount > tierCeiling && currentScalerBps < MAX_RISK_SCALER_BPS) {
            uint256 nextTierCeiling = tierCeiling * TIER_MULTIPLIER;
            if (TIER_MULTIPLIER == 0) break;
            if (tierCeiling > type(uint256).max / TIER_MULTIPLIER) {
                break;
            }
            tierCeiling = nextTierCeiling;

            if (currentScalerBps > type(uint256).max / TIER_MULTIPLIER) {
                currentScalerBps = MAX_RISK_SCALER_BPS;
                break;
            }
            currentScalerBps = currentScalerBps * TIER_MULTIPLIER;
        }
        if (currentScalerBps > MAX_RISK_SCALER_BPS) {
            currentScalerBps = MAX_RISK_SCALER_BPS;
        }
        return currentScalerBps;
    }
}
