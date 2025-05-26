// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library TokenConstants {
    uint256 constant MAX_FEE_PERCENT_BPS = 500; // Example value
    uint256 constant BASIS_POINTS = 10000;      // Example value
    uint256 constant TIER_MULTIPLIER = 10;
    uint256 constant MIN_FEE_WEI = 10**13; // 0.01 T3 (assuming 18 decimals)
    uint256 constant BASE_RISK_SCALER_BPS = 1; // 0.01% per tier base
    uint256 constant MAX_RISK_SCALER_BPS = BASIS_POINTS; // 100% max scaler
    //moved directly to the Fee calculation library
    uint128 constant FEE_PRECISION_MULTIPLIER = 1000;
    // --- Fee Structure Constants ---
    uint256 constant EFFECTIVE_BASIS_POINTS = BASIS_POINTS * FEE_PRECISION_MULTIPLIER;

}

library T3TokenLogicLibrary {
    // Move pure/view logic here. Example for calculateRiskFactor:
    function calculateRiskFactor(
        uint256 creationTime,
        uint256 lastReversal,
        uint32 reversalCount,
        uint32 abnormalTxCount,
        uint256 BASIS_POINTS
    ) internal view returns (uint256) {
        uint256 riskFactor = BASIS_POINTS;

        if (creationTime > 0 && block.timestamp - creationTime < 7 days) {
            riskFactor += 5000;
        }
        if (lastReversal > 0 && block.timestamp - lastReversal < 30 days) {
            riskFactor += 10000;
        }

        unchecked {
            uint256 maxReversalPenalty = 50000;
            uint256 reversalPenalty = uint256(reversalCount) * 1000;
            riskFactor += reversalPenalty > maxReversalPenalty ? maxReversalPenalty : reversalPenalty;

            uint256 maxAbnormalPenalty = 25000;
            uint256 abnormalPenalty = uint256(abnormalTxCount) * 500;
            riskFactor += abnormalPenalty > maxAbnormalPenalty ? maxAbnormalPenalty : abnormalPenalty;
        }

        return riskFactor;
    }

    function calculateAdaptiveHalfLife(uint256 amount,uint256 halfLifeDuration, 
                                        uint256 txCount, uint256 avg_count, uint256 avg_total,  uint256 minHalfLifeDuration, uint256 maxHalfLifeDuration) 
                                        internal pure returns (uint256) 
    {
        uint256 currentHalfLife = halfLifeDuration;

        if (txCount > 0) {
            unchecked {
                uint256 reductionPercent = (txCount * 10 > 90) ? 90 : txCount * 10;
                currentHalfLife = currentHalfLife * (100 - reductionPercent) / 100;
            }
        }
        
        
        if (avg_count > 0 && avg_total > 0) {
            unchecked {
                uint256 avgAmount = avg_total / avg_count;
                if (amount > avgAmount * 10) {
                    uint256 doubledDuration = currentHalfLife * 2;
                    if (currentHalfLife <= type(uint256).max / 2) {
                        currentHalfLife = doubledDuration;
                    } else {
                        currentHalfLife = type(uint256).max;
                    }
                }
            }
        }
        
        if (currentHalfLife < minHalfLifeDuration) { 
            currentHalfLife = minHalfLifeDuration; 
        }
        else if (currentHalfLife > maxHalfLifeDuration) { 
            currentHalfLife = maxHalfLifeDuration; 
        }
        
        return currentHalfLife;
    }


}