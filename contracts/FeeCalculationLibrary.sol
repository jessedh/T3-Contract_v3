// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/math/Math.sol";

// If EFFECTIVE_BASIS_POINTS is not defined in ITokenConstants, define it here:
uint256 constant EFFECTIVE_BASIS_POINTS = 1e8; // Set this to the correct value used in your project

/**
 * @title FeeCalculationLibrary
 * @dev A library for pure and view functions related to fee calculations.
 * This helps reduce the main contract's bytecode size.
 * Optimized for gas efficiency and reduced contract size.
 */
library FeeCalculationLibrary {
    // Import constants from shared interface instead of duplicating
    using Math for uint256;

    // Define a struct for a single tier entry with optimized storage
    struct TierEntry {
        uint128 ceiling;  // Use uint128 to support large values
        uint128 rate;    // Increased from uint16 to uint128 to fit large values
        uint56 reserved; // Adjusted reserved to maintain 256-bit slot packing
    }

    /**
     * @dev Calculates the base fee amount based on a tiered structure.
     * @param amount The amount for which to calculate the base fee.
     * @return The calculated base fee amount.
     */
    function calculateBaseFeeAmount(uint256 amount) internal pure returns (uint256) {
        if (amount == 0) return 0;
        uint256 totalFee = 0;

        // Use an array of TierEntry structs for the tiers with optimized storage
        //ie6 = 1000
        TierEntry[10] memory tiers;
        tiers[0] = TierEntry({ceiling: uint128(1e16), rate: uint128(100000 * 1e6), reserved: 0}); // 0.01 ether
        tiers[1] = TierEntry({ceiling: uint128(1e17), rate: uint128(10000 * 1e6), reserved: 0});  // 0.10 ether
        tiers[2] = TierEntry({ceiling: uint128(1e18), rate: uint128(1000 * 1e6), reserved: 0});   // 1.00 ether
        tiers[3] = TierEntry({ceiling: uint128(1e19), rate: uint128(100 * 1e6), reserved: 0});    // 10.0 ether
        tiers[4] = TierEntry({ceiling: uint128(1e20), rate: uint128(10 * 1e6), reserved: 0});     // 100.0 ether
        tiers[5] = TierEntry({ceiling: uint128(1e21), rate: uint128(1 * 1e6), reserved: 0});      // 1000.0 ether
        tiers[6] = TierEntry({ceiling: uint128(1e22), rate: uint128((1 * 1e6) / 10), reserved: 0});   // 10000.0 ether
        tiers[7] = TierEntry({ceiling: uint128(1e23), rate: uint128((1 * 1e6) / 100), reserved: 0});  // 100000.0 ether
        tiers[8] = TierEntry({ceiling: uint128(1e24), rate: uint128((1 * 1e6) / 1000), reserved: 0}); // 1000000.0 ether
        // For the last tier, we use the max value of uint128
        tiers[9] = TierEntry({ceiling: type(uint128).max, rate: uint128((1 * 1e6) / 10000), reserved: 0});

        // Optimized loop with unchecked counter
        for (uint i = 0; i < tiers.length;) {
            uint256 tierCeiling = tiers[i].ceiling;
            uint256 scaledTierRateBps = tiers[i].rate;
            uint256 tierFloor = (i == 0) ? 0 : tiers[i-1].ceiling;
            uint256 amountInTier;

            if (amount > tierFloor) {
                if (amount >= tierCeiling) {
                    if (tierCeiling > tierFloor) {
                        amountInTier = tierCeiling - tierFloor;
                    } else {
                        amountInTier = 0;
                        if (tierCeiling == type(uint128).max) break;
                    }
                } else {
                    amountInTier = amount - tierFloor;
                }
            }
                totalFee += Math.mulDiv(amountInTier, scaledTierRateBps, EFFECTIVE_BASIS_POINTS);
            if (amountInTier > 0) {
                // Use OpenZeppelin's Math library for more precise calculations
                totalFee += Math.mulDiv(amountInTier, scaledTierRateBps, EFFECTIVE_BASIS_POINTS);
            }

            if (amount < tierCeiling || tierCeiling == type(uint128).max) break;
            
            // Unchecked increment to save gas
            unchecked { ++i; }
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
        uint256 currentScalerBps = 10000; // ITokenConstants.BASE_RISK_SCALER_BPS;

        // Optimized loop with unchecked math where overflow is impossible
        while (amount > tierCeiling && currentScalerBps < 100000) { // ITokenConstants.MAX_RISK_SCALER_BPS
            unchecked {
                // Safe multiplication check
                if (tierCeiling > type(uint256).max / 10) { // ITokenConstants.TIER_MULTIPLIER
                    break;
                }
                tierCeiling = tierCeiling * 10; // ITokenConstants.TIER_MULTIPLIER
                
                // Safe multiplication check
                if (currentScalerBps > type(uint256).max / 10) { // ITokenConstants.TIER_MULTIPLIER
                    currentScalerBps = 100000; // ITokenConstants.MAX_RISK_SCALER_BPS;
                    break;
                }
                currentScalerBps = currentScalerBps * 10; // ITokenConstants.TIER_MULTIPLIER
            }
        }
        
        // Cap at maximum risk scaler
        if (currentScalerBps > 100000) {
            currentScalerBps = 100000;
        }
        return currentScalerBps;
    }
    
    /**
     * @dev Quick estimation of fee for common cases - optimized for gas efficiency
     * @param amount The amount for which to estimate the fee
     * @return An estimated fee amount for common transaction sizes
     */
    function quickFeeEstimate(uint256 amount) internal pure returns (uint256) {
        // Simple tiered structure for common amounts
        if (amount < 1e16) { // < 0.01 ETH
            return amount * 100 / 10000; // 1% fee
        } else if (amount < 1e18) { // < 1 ETH
            return amount * 50 / 10000; // 0.5% fee
        } else if (amount < 1e20) { // < 100 ETH
            return amount * 25 / 10000; // 0.25% fee
        } else {
            return amount * 10 / 10000; // 0.1% fee
        }
    }
}
