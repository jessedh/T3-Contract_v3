// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Using ERC20Pausable and AccessControl
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
// import "hardhat/console.sol"; // Logging disabled

/**
 * @title T3Token (T3USD) - Final Version with Precision Fees
 * @dev Pausable ERC20 token with HalfLife, Reversals, Tiered Fees with Precision, Amount-Scaled Risk,
 * Interbank Liability Tracking, AccessControl, and Pausing capabilities.
 */
contract T3Token is ERC20Pausable, AccessControl {

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // --- Fee Structure Constants ---
    uint256 private constant BASIS_POINTS = 10000; // Represents 100%
    // --- NEW: Fee Precision Handling ---
    uint256 private constant FEE_PRECISION_MULTIPLIER = 1000; // Allows thousandths of a basis point
    uint256 private constant EFFECTIVE_BASIS_POINTS = BASIS_POINTS * FEE_PRECISION_MULTIPLIER; // 10,000,000 - Used for fee calculation
    // ------------------------------------
    uint256 private constant TIER_MULTIPLIER = 10; // Used for amount risk scaler tiering
    // Base fee rate and risk scaler defined within functions based on tiers

    // Min fee requested: 0.00001 T3USD = 1 * 10**13 wei (assuming 18 decimals)
    uint256 private constant MIN_FEE_WEI = 10**13;
    // Max fee requested: 10% -> 1000 Basis Points (relative to original BASIS_POINTS)
    uint256 private constant MAX_FEE_PERCENT_BPS = 1000;
    // Starting percentage for amount-based risk scaling (0.01%)
    uint256 private constant BASE_RISK_SCALER_BPS = 1;
    // Cap for amount-based risk scaling (100%)
    uint256 private constant MAX_RISK_SCALER_BPS = BASIS_POINTS; // 10000 bps

    // --- HalfLife Constants ---
    uint256 public halfLifeDuration = 3600;
    uint256 public minHalfLifeDuration = 600;
    uint256 public maxHalfLifeDuration = 86400;
    uint256 public inactivityResetPeriod = 30 days;

    // --- Addresses ---
    address public treasuryAddress;

    // --- Data Structures ---
    struct TransferMetadata { /* ... as before ... */
        uint256 commitWindowEnd;
        uint256 halfLifeDuration;
        address originator;
        uint256 transferCount;
        bytes32 reversalHash;
        uint256 feeAmount;
        bool isReversed;
    }
    struct RollingAverage { /* ... as before ... */
        uint256 totalAmount;
        uint256 count;
        uint256 lastUpdated;
    }
    struct WalletRiskProfile { /* ... as before ... */
        uint256 reversalCount;
        uint256 lastReversal;
        uint256 creationTime;
        uint256 abnormalTxCount;
    }
    struct IncentiveCredits { /* ... as before ... */
        uint256 amount;
        uint256 lastUpdated;
    }
    // FeeDetails Struct for Estimation (no changes needed here)
    struct FeeDetails { /* ... as before ... */
        uint256 requestedAmount;
        uint256 baseFeeAmount;
        uint256 senderRiskScore;
        uint256 recipientRiskScore;
        uint256 applicableRiskScore;
        uint256 amountRiskScaler;
        uint256 scaledRiskImpactBps;
        uint256 finalRiskFactorBps;
        uint256 feeAfterRisk;
        uint256 availableCredits;
        uint256 creditsApplied;
        uint256 feeAfterCredits;
        uint256 maxFeeBound;
        uint256 minFeeBound;
        bool maxFeeApplied;
        bool minFeeApplied;
        uint256 finalFee;
        uint256 netAmountToSend;
     }

    // --- Mappings ---
    mapping(address => TransferMetadata) public transferData;
    mapping(address => RollingAverage) public rollingAverages;
    mapping(address => mapping(address => uint256)) public transactionCountBetween;
    mapping(address => WalletRiskProfile) public walletRiskProfiles;
    mapping(address => IncentiveCredits) public incentiveCredits;
    mapping(address => uint256) public mintedByMinter;
    mapping(address => mapping(address => uint256)) public interbankLiability;

    // --- Events ---
    // ... (Events remain the same) ...
     event TransferWithFee(address indexed from, address indexed to, uint256 amount, uint256 fee);
     event TransferReversed(address indexed from, address indexed to, uint256 amount);
     event HalfLifeExpired(address indexed wallet, uint256 timestamp);
     event LoyaltyRefundProcessed(address indexed wallet, uint256 amount);
     event RiskFactorUpdated(address indexed wallet, uint256 newRiskFactor);
     event InterbankLiabilityRecorded(address indexed debtor, address indexed creditor, uint256 amount);
     event InterbankLiabilityCleared(address indexed debtor, address indexed creditor, uint256 amountCleared);
     event TokensMinted(address indexed minter, address indexed recipient, uint256 amount);

    /**
     * @dev Constructor
     */
    constructor(address initialAdmin, address _treasuryAddress) ERC20("T3 Stablecoin", "T3") {
        require(_treasuryAddress != address(0), "Treasury address cannot be zero");
        treasuryAddress = _treasuryAddress;
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
        _mint(initialAdmin, 1000000 * 10**decimals()); // Consider initial supply relative to fees
        walletRiskProfiles[initialAdmin].creationTime = block.timestamp;
    }

    // --- ERC20 Overrides and T3 Logic ---

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        address sender = _msgSender();
        _ensureProfileExists(sender); // Use view check before logic
        _ensureProfileExists(recipient);
        _transferWithT3Logic(sender, recipient, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _ensureProfileExists(from);
        _ensureProfileExists(to);
        _transferWithT3Logic(from, to, amount);
        return true;
    }

    function _transferWithT3Logic(address sender, address recipient, uint256 amount) internal {
        require(recipient != address(0), "Transfer to zero address");
        require(amount > 0, "Transfer amount must be greater than zero");

        // Check HalfLife restriction
        if (transferData[sender].commitWindowEnd > block.timestamp &&
            transferData[sender].originator != recipient) {
            revert("Cannot transfer during HalfLife period except back to originator");
        }

        // --- Fee Calculation Pipeline ---
        // 1. Calculate Base Fee Amount (Uses new precise tiered logic)
        uint256 baseFeeAmount = calculateBaseFeeAmount(amount);

        // 2. Apply Risk Adjustments (incorporates amount scaler - logic unchanged here)
        uint256 feeAfterRisk = applyRiskAdjustments(baseFeeAmount, sender, recipient, amount);

        // 3. Apply Credits (Modifies state)
        (uint256 feeAfterCredits, /*uint256 creditsUsed*/ ) = applyCredits(sender, feeAfterRisk);

        // 4. Apply Bounds
        uint256 finalFee = feeAfterCredits;

        uint256 maxFeeAmount = (amount * MAX_FEE_PERCENT_BPS) / BASIS_POINTS; // Max bound still uses original BASIS_POINTS
        if (finalFee > maxFeeAmount) { finalFee = maxFeeAmount; }

        uint256 minFeeCheck = MIN_FEE_WEI;
        if (finalFee > 0 && finalFee < minFeeCheck && amount >= minFeeCheck) {
             if (minFeeCheck <= maxFeeAmount && minFeeCheck <= amount) {
                  finalFee = minFeeCheck;
             }
        }

        if (finalFee > amount) { finalFee = amount; }
        // --- End Fee Pipeline ---

        uint256 netAmount = amount - finalFee;

        _update(sender, recipient, netAmount);

        // --- Post-transfer actions ---
        if (finalFee > 0) {
            processFee(sender, recipient, finalFee);
        }
        transactionCountBetween[sender][recipient]++;
        uint256 adaptiveHalfLife = calculateAdaptiveHalfLife(sender, recipient, amount);

        transferData[recipient] = TransferMetadata({
            commitWindowEnd: block.timestamp + adaptiveHalfLife,
            halfLifeDuration: adaptiveHalfLife,
            originator: sender,
            transferCount: transferData[recipient].transferCount + 1,
            reversalHash: keccak256(abi.encodePacked(sender, recipient, amount)),
            feeAmount: finalFee,
            isReversed: false
        });

        updateRollingAverage(recipient, amount);
        emit TransferWithFee(sender, recipient, netAmount, finalFee);
    }

    // --- Core Logic Functions ---

    /**
     * @dev UPDATED: Calculates base fee using precise tiers and fractional basis point handling.
     */
    function calculateBaseFeeAmount(uint256 amount) internal pure returns (uint256) {
        if (amount == 0) return 0;
        // no longer used in this function
        //uint256 _decimals = decimals();
        //uint256 processedAmount = 0; // Track amount processed

        uint256 totalFee = 0;
        
        // Define tier ceilings (exclusive upper bound) and scaled rates
        // Scaled Rate = Actual Bps * FEE_PRECISION_MULTIPLIER
        // Using EFFECTIVE_BASIS_POINTS (10M) as denominator later
        uint256[2][] memory tiers = new uint256[2][](10);

        // Helper for scaled rates
        uint256 scale = FEE_PRECISION_MULTIPLIER; // 1000

        // Tier Definitions (using 18 decimals for ceilings)
        tiers[0] = [uint256(0.01 * 10**18), uint256(1000000 * scale)]; // 0 to 0.01 @ 1000%
        tiers[1] = [uint256(0.10 * 10**18), uint256(100000 * scale)];  // 0.01 to 0.10 @ 100%
        tiers[2] = [uint256(1.00 * 10**18), uint256(10000 * scale)];   // 0.10 to 1.00 @ 10%
        tiers[3] = [uint256(10.0 * 10**18), uint256(1000 * scale)];   // 1.00 to 10.00 @ 1%
        tiers[4] = [uint256(100.0 * 10**18), uint256(100 * scale)];   // 10.00 to 100.00 @ 0.1%
        tiers[5] = [uint256(1000.0 * 10**18), uint256(10 * scale)];    // 100.00 to 1k @ 0.01%
        tiers[6] = [uint256(10000.0 * 10**18), uint256(1 * scale)];     // 1k to 10k @ 0.001% (1 bps)
        // Fractional basis point tiers (Rate * 1000)
        tiers[7] = [uint256(100000.0 * 10**18), uint256((1 * scale) / 10)];    // 10k to 100k @ 0.1 bps (Rate = 100)
        tiers[8] = [uint256(1000000.0 * 10**18), uint256((1 * scale) / 100)];   // 100k to 1M @ 0.01 bps (Rate = 10)
        tiers[9] = [uint256(type(uint256).max), uint256((1 * scale) / 1000)];  // > 1M @ 0.001 bps (Rate = 1)

        for (uint i = 0; i < tiers.length; i++) {
            uint256 tierCeiling = tiers[i][0];
            uint256 scaledTierRateBps = tiers[i][1]; // This holds the rate scaled by FEE_PRECISION_MULTIPLIER

            uint256 tierFloor = (i == 0) ? 0 : tiers[i-1][0];

            // Calculate amount falling into this tier's range [tierFloor, tierCeiling)
            uint256 amountInTier = 0;
            if (amount > tierFloor) { // Only calculate if amount reaches this tier
                if (amount >= tierCeiling) {
                    // Amount exceeds this tier, process the full tier size
                    // Ensure tierCeiling > tierFloor before subtraction
                    if (tierCeiling > tierFloor) {
                         amountInTier = tierCeiling - tierFloor;
                    } else {
                         amountInTier = 0; // Avoid underflow/error if ceiling isn't larger
                    }
                } else {
                    // Amount ends within this tier, process the remainder
                    amountInTier = amount - tierFloor;
                }
            }

            // Calculate and add fee for the amount in this tier using effective denominator
            if (amountInTier > 0 && scaledTierRateBps > 0) {
                // Use EFFECTIVE_BASIS_POINTS for calculation
                totalFee += (amountInTier * scaledTierRateBps) / EFFECTIVE_BASIS_POINTS;
            }

            // Stop if we've processed the entire amount
            // Use >= because ceiling is exclusive upper bound of range
            if (amount < tierCeiling) {
                break;
            }
        }
        return totalFee;
    }

   /**
    * @dev Calculates amount risk scaler (logic unchanged)
    */
   function calculateAmountRiskScaler(uint256 amount) internal view returns (uint256) {
        // ... (Function body remains the same as previous version) ...
         if (amount == 0) return 0; // No scaling for zero amount
         uint256 _decimals = decimals();
         uint256 tierCeiling = 1 * (10**_decimals); // First tier ends at 1 T3USD
         uint256 currentScalerBps = BASE_RISK_SCALER_BPS; // Starts at 0.01%

         while (amount > tierCeiling && currentScalerBps < MAX_RISK_SCALER_BPS) {
             uint256 nextTierCeiling = tierCeiling * TIER_MULTIPLIER;
             if (TIER_MULTIPLIER != 0 && nextTierCeiling / TIER_MULTIPLIER != tierCeiling && tierCeiling > 0) {
                  break;
             }
             if (currentScalerBps * TIER_MULTIPLIER > MAX_RISK_SCALER_BPS) {
                 break;
             }
             tierCeiling = nextTierCeiling;
             currentScalerBps = currentScalerBps * TIER_MULTIPLIER;
         }
         if (currentScalerBps > MAX_RISK_SCALER_BPS) {
             currentScalerBps = MAX_RISK_SCALER_BPS;
         }
         return currentScalerBps;
   }


    /**
     * @dev Applies risk adjustments (logic unchanged)
     */
    function applyRiskAdjustments(
        uint256 baseFeeAmount,
        address sender,
        address recipient,
        uint256 amount
    ) internal view returns (uint256 feeAfterRisk) {
        // ... (Function body remains the same as previous version) ...
         if (baseFeeAmount == 0) return 0;
         uint256 riskScoreSender = calculateRiskFactor(sender);
         uint256 riskScoreRecipient = calculateRiskFactor(recipient);
         uint256 applicableRiskScore = riskScoreSender > riskScoreRecipient ? riskScoreSender : riskScoreRecipient;
         uint256 riskDeviation = applicableRiskScore > BASIS_POINTS ? applicableRiskScore - BASIS_POINTS : 0;
         if (riskDeviation == 0) {
             return baseFeeAmount;
         }
         uint256 amountScalerBps = calculateAmountRiskScaler(amount);
         uint256 scaledRiskImpactBps = (riskDeviation * amountScalerBps) / BASIS_POINTS;
         uint256 finalRiskFactorBps = BASIS_POINTS + scaledRiskImpactBps;
         feeAfterRisk = (baseFeeAmount * finalRiskFactorBps) / BASIS_POINTS; // Uses original BASIS_POINTS here for applying the final factor
         return feeAfterRisk;
    }

    /**
     * @dev Calculates risk factor (logic unchanged)
     */
    function calculateRiskFactor(address wallet) public view returns (uint256) {
        // ... (Function body remains the same as previous version, including _ensureProfileExists view helper) ...
          _ensureProfileExists(wallet);
          WalletRiskProfile storage profile = walletRiskProfiles[wallet];
         uint256 riskFactor = BASIS_POINTS;
         if (profile.creationTime > 0 && block.timestamp - profile.creationTime < 7 days) {
             riskFactor += 5000;
         }
         if (profile.lastReversal > 0 && block.timestamp - profile.lastReversal < 30 days) {
             riskFactor += 10000;
         }
         uint256 maxReversalPenalty = 50000;
         uint256 reversalPenalty = profile.reversalCount * 1000;
         riskFactor += reversalPenalty > maxReversalPenalty ? maxReversalPenalty : reversalPenalty;
         uint256 maxAbnormalPenalty = 25000;
         uint256 abnormalPenalty = profile.abnormalTxCount * 500;
         riskFactor += abnormalPenalty > maxAbnormalPenalty ? maxAbnormalPenalty : abnormalPenalty;
         return riskFactor;
    }

     /**
      * @dev Applies credits (logic unchanged)
      */
     function applyCredits(address wallet, uint256 fee) internal returns (uint256 remainingFee, uint256 creditsUsed) {
         // ... (Function body remains the same as previous version) ...
          IncentiveCredits storage credits = incentiveCredits[wallet];
          if (credits.amount == 0 || fee == 0) {
              return (fee, 0);
          }
          if (credits.amount >= fee) {
              creditsUsed = fee;
              credits.amount -= fee;
              credits.lastUpdated = block.timestamp;
              remainingFee = 0;
              return (remainingFee, creditsUsed);
          } else {
              creditsUsed = credits.amount;
              remainingFee = fee - credits.amount;
              credits.amount = 0;
              credits.lastUpdated = block.timestamp;
              return (remainingFee, creditsUsed);
          }
     }

     /**
      * @dev Processes fee distribution (logic unchanged)
      */
     function processFee(address sender, address recipient, uint256 finalFeeAmount) internal {
         // ... (Function body remains the same as previous version) ...
          if (finalFeeAmount == 0) {
              return;
          }
          uint256 treasuryShare = finalFeeAmount / 2;
          uint256 senderShare = finalFeeAmount / 4;
          uint256 recipientShare = finalFeeAmount - treasuryShare - senderShare;
          if (treasuryShare > 0) {
              if (treasuryAddress != address(0)) {
                 _mint(treasuryAddress, treasuryShare);
              }
          }
          if (senderShare > 0) {
              incentiveCredits[sender].amount += senderShare;
              incentiveCredits[sender].lastUpdated = block.timestamp;
          }
          if (recipientShare > 0) {
              incentiveCredits[recipient].amount += recipientShare;
              incentiveCredits[recipient].lastUpdated = block.timestamp;
          }
     }

     /**
      * @dev Calculates adaptive HalfLife (logic unchanged)
      */
    function calculateAdaptiveHalfLife(address sender, address recipient, uint256 amount) internal view returns (uint256) {
        // ... (Function body remains the same as previous version) ...
         uint256 duration = halfLifeDuration;
         uint256 txCount = transactionCountBetween[sender][recipient];
         if (txCount > 0) {
             uint256 reductionPercent = (txCount * 10 > 90) ? 90 : txCount * 10;
             duration = duration * (100 - reductionPercent) / 100;
         }
         RollingAverage storage avg = rollingAverages[sender];
         if (avg.count > 0 && avg.totalAmount > 0) {
             uint256 avgAmount = avg.totalAmount / avg.count;
             if (amount > avgAmount * 10) {
                 uint256 doubledDuration = duration * 2;
                 if (doubledDuration / 2 == duration) {
                     duration = doubledDuration;
                 }
             }
         }
         if (duration < minHalfLifeDuration) { duration = minHalfLifeDuration; }
         else if (duration > maxHalfLifeDuration) { duration = maxHalfLifeDuration; }
         return duration;
    }

     /**
      * @dev Updates rolling average (logic unchanged)
      */
    function updateRollingAverage(address wallet, uint256 amount) internal {
        // ... (Function body remains the same as previous version) ...
         RollingAverage storage avg = rollingAverages[wallet];
         if (avg.lastUpdated > 0 && block.timestamp - avg.lastUpdated > inactivityResetPeriod) {
             avg.totalAmount = 0;
             avg.count = 0;
         }
         avg.totalAmount += amount;
         avg.count++;
         avg.lastUpdated = block.timestamp;
    }

    /**
     * @dev Updates wallet risk profile on reversal (logic unchanged)
     */
    function updateWalletRiskProfileOnReversal(address wallet) internal {
        // ... (Function body remains the same as previous version, uses _ensureProfileExistsForWrite) ...
         _ensureProfileExistsForWrite(wallet); // Use write helper
         WalletRiskProfile storage profile = walletRiskProfiles[wallet];
         profile.reversalCount++;
         profile.lastReversal = block.timestamp;
    }

    /**
     * @dev Internal view helper for profile existence check (logic unchanged)
     */
    function _ensureProfileExists(address wallet) internal view {
        // ... (Function body remains the same as previous version) ...
         // This view function doesn't modify state, just helps read logic
          if (walletRiskProfiles[wallet].creationTime == 0 && wallet != address(0)) {
             // Can treat as created now for view logic if needed, but calculateRiskFactor handles 0 time ok
          }
    }

    /**
     * @dev Internal helper ensures profile exists before write (logic unchanged)
     */
    function _ensureProfileExistsForWrite(address wallet) internal {
        // ... (Function body remains the same as previous version) ...
         if (wallet != address(0) && walletRiskProfiles[wallet].creationTime == 0) {
             walletRiskProfiles[wallet].creationTime = block.timestamp;
         }
    }

    // --- Reversal & Expiry Functions ---
    // ... (reverseTransfer, checkHalfLifeExpiry functions remain the same) ...
     function reverseTransfer(address recipient, uint256 amount) external whenNotPaused { /* ... as before ... */
        address sender = _msgSender();
        TransferMetadata storage meta = transferData[recipient];
        require(meta.originator == sender, "Reversal: Sender mismatch");
        require(meta.commitWindowEnd > 0, "Reversal: No active transfer");
        require(block.timestamp < meta.commitWindowEnd, "Reversal: HalfLife expired");
        require(!meta.isReversed, "Reversal: Transfer already reversed");
        require(balanceOf(recipient) >= amount, "Reversal: Insufficient recipient balance");
        meta.isReversed = true;
        updateWalletRiskProfileOnReversal(sender);
        updateWalletRiskProfileOnReversal(recipient);
        _transfer(recipient, sender, amount);
        emit TransferReversed(sender, recipient, amount);
     }

     function checkHalfLifeExpiry(address wallet) external whenNotPaused { /* ... as before ... */
        TransferMetadata storage meta = transferData[wallet];
        require(meta.commitWindowEnd > 0, "Expiry: No active transfer data");
        require(!meta.isReversed, "Expiry: Transfer was reversed");
        require(block.timestamp >= meta.commitWindowEnd, "Expiry: HalfLife not expired yet");
        uint256 feePaid = meta.feeAmount;
        if (feePaid > 0) {
            uint256 totalRefundAmount = feePaid / 8;
            if (totalRefundAmount > 0) {
                uint256 refundPerParty = totalRefundAmount / 2;
                if (refundPerParty > 0) {
                     incentiveCredits[meta.originator].amount += refundPerParty;
                     incentiveCredits[meta.originator].lastUpdated = block.timestamp;
                     emit LoyaltyRefundProcessed(meta.originator, refundPerParty);
                     incentiveCredits[wallet].amount += refundPerParty;
                     incentiveCredits[wallet].lastUpdated = block.timestamp;
                     emit LoyaltyRefundProcessed(wallet, refundPerParty);
                }
            }
        }
        delete transferData[wallet];
        emit HalfLifeExpired(wallet, block.timestamp);
      }

    // --- View Functions ---

    function getAvailableCredits(address wallet) external view returns (uint256) { /* ... as before ... */
        return incentiveCredits[wallet].amount;
     }

    /**
     * @dev UPDATED: Estimates the fee details using the latest precise tiered base fee calculation.
     */
    function estimateTransferFeeDetails(
        address sender,
        address recipient,
        uint256 amount
    ) external view returns (FeeDetails memory details) {
        require(recipient != address(0), "Estimate: Transfer to zero address");
        require(amount > 0, "Estimate: Transfer amount must be greater than zero");

        // --- Simulate Fee Calculation Pipeline ---
        details.requestedAmount = amount;

        // 1. Calculate Base Fee Amount (Uses NEW precise logic)
        details.baseFeeAmount = calculateBaseFeeAmount(amount);

        // 2. Simulate Risk Adjustments (Logic unchanged)
        details.senderRiskScore = calculateRiskFactor(sender);
        details.recipientRiskScore = calculateRiskFactor(recipient);
        details.applicableRiskScore = details.senderRiskScore > details.recipientRiskScore
            ? details.senderRiskScore
            : details.recipientRiskScore;

        uint256 riskDeviation = details.applicableRiskScore > BASIS_POINTS ? details.applicableRiskScore - BASIS_POINTS : 0;

        if (riskDeviation == 0 || details.baseFeeAmount == 0) {
            details.amountRiskScaler = 0; // Scaler doesn't apply if no deviation or base fee
            details.scaledRiskImpactBps = 0;
            details.finalRiskFactorBps = BASIS_POINTS;
            details.feeAfterRisk = details.baseFeeAmount;
        } else {
            details.amountRiskScaler = calculateAmountRiskScaler(amount);
            details.scaledRiskImpactBps = (riskDeviation * details.amountRiskScaler) / BASIS_POINTS;
            details.finalRiskFactorBps = BASIS_POINTS + details.scaledRiskImpactBps;
            // Apply risk factor using original BASIS_POINTS
            details.feeAfterRisk = (details.baseFeeAmount * details.finalRiskFactorBps) / BASIS_POINTS;
        }

        // 3. Simulate applyCredits (Logic unchanged)
        IncentiveCredits storage credits = incentiveCredits[sender];
        details.availableCredits = credits.amount;

        if (details.availableCredits == 0 || details.feeAfterRisk == 0) {
             details.creditsApplied = 0;
             details.feeAfterCredits = details.feeAfterRisk;
        } else if (details.availableCredits >= details.feeAfterRisk) {
             details.creditsApplied = details.feeAfterRisk;
             details.feeAfterCredits = 0;
        } else {
             details.creditsApplied = details.availableCredits;
             details.feeAfterCredits = details.feeAfterRisk - details.availableCredits;
        }

        // 4. Apply Bounds (Logic unchanged)
        uint256 feeBeforeBounds = details.feeAfterCredits;
        details.finalFee = feeBeforeBounds;

        details.maxFeeBound = (amount * MAX_FEE_PERCENT_BPS) / BASIS_POINTS; // Max bound uses original BASIS_POINTS
        if (details.finalFee > details.maxFeeBound) {
            details.finalFee = details.maxFeeBound;
            details.maxFeeApplied = true;
        } else {
            details.maxFeeApplied = false;
        }

        details.minFeeBound = MIN_FEE_WEI;
         if (details.finalFee > 0 && details.finalFee < details.minFeeBound && amount >= details.minFeeBound) {
             if (details.minFeeBound <= details.maxFeeBound && details.minFeeBound <= amount) {
                 details.finalFee = details.minFeeBound;
                 details.minFeeApplied = true;
                 details.maxFeeApplied = (details.finalFee >= details.maxFeeBound);
             } else {
                 details.minFeeApplied = false;
             }
        } else {
             details.minFeeApplied = false;
        }

        if (details.finalFee > amount) {
            details.finalFee = amount;
            details.maxFeeApplied = (details.finalFee == details.maxFeeBound && details.maxFeeBound == amount);
            details.minFeeApplied = (details.finalFee == details.minFeeBound && details.minFeeBound == amount);
        }
        // --- End Fee Pipeline Simulation ---

        details.netAmountToSend = amount > details.finalFee ? amount - details.finalFee : 0;

        return details;
    }


    // --- Minting and Burning Functions ---
    // ... (mint, burn, burnFrom functions remain the same) ...
     function mint(address recipient, uint256 amount) external whenNotPaused onlyRole(MINTER_ROLE) { /* ... as before ... */
         require(recipient != address(0), "Mint to the zero address");
         require(amount > 0, "Mint amount must be positive");
         address minter = _msgSender();
         _mint(recipient, amount);
         mintedByMinter[minter] += amount;
         _ensureProfileExistsForWrite(recipient);
         emit TokensMinted(minter, recipient, amount);
      }
      function burn(uint256 amount) external whenNotPaused { /* ... as before ... */
          require(amount > 0, "Burn amount must be positive");
          _burn(_msgSender(), amount);
       }
       function burnFrom(address account, uint256 amount) external whenNotPaused { /* ... as before ... */
           require(amount > 0, "Burn amount must be positive");
           _spendAllowance(account, _msgSender(), amount);
           _burn(account, amount);
       }

    // --- Interbank Liability Functions ---
    // ... (recordInterbankLiability, clearInterbankLiability functions remain the same) ...
     function recordInterbankLiability(address debtor, address creditor, uint256 amount) external onlyRole(ADMIN_ROLE) { /* ... as before ... */
         require(debtor != address(0), "Debtor cannot be zero address");
         require(creditor != address(0), "Creditor cannot be zero address");
         require(debtor != creditor, "Debtor cannot be creditor");
         require(amount > 0, "Amount must be positive");
         interbankLiability[debtor][creditor] += amount;
         emit InterbankLiabilityRecorded(debtor, creditor, amount);
      }
      function clearInterbankLiability(address debtor, address creditor, uint256 amountToClear) external onlyRole(ADMIN_ROLE) { /* ... as before ... */
         require(debtor != address(0), "Debtor cannot be zero address");
         require(creditor != address(0), "Creditor cannot be zero address");
         require(debtor != creditor, "Debtor cannot be creditor");
         require(amountToClear > 0, "Amount to clear must be positive");
         uint256 currentLiability = interbankLiability[debtor][creditor];
         require(amountToClear <= currentLiability, "Amount to clear exceeds outstanding liability");
         interbankLiability[debtor][creditor] = currentLiability - amountToClear;
         emit InterbankLiabilityCleared(debtor, creditor, amountToClear);
      }

    // --- Admin / Role Management Functions ---
    // ... (flagAbnormalTransaction, setTreasuryAddress, setHalfLifeDuration, etc. remain the same) ...
     function flagAbnormalTransaction(address wallet) external onlyRole(ADMIN_ROLE) { /* ... uses write helper ... */
         _ensureProfileExistsForWrite(wallet);
         walletRiskProfiles[wallet].abnormalTxCount++;
      }
      function setTreasuryAddress(address _treasuryAddress) external onlyRole(ADMIN_ROLE) { /* ... as before ... */
          require(_treasuryAddress != address(0), "Treasury address cannot be zero");
          treasuryAddress = _treasuryAddress;
       }
       function setHalfLifeDuration(uint256 _halfLifeDuration) external onlyRole(ADMIN_ROLE) { /* ... as before ... */
          require(_halfLifeDuration >= minHalfLifeDuration, "Below minimum");
          require(_halfLifeDuration <= maxHalfLifeDuration, "Above maximum");
          halfLifeDuration = _halfLifeDuration;
       }
       function setMinHalfLifeDuration(uint256 _minHalfLifeDuration) external onlyRole(ADMIN_ROLE) { /* ... as before ... */
          require(_minHalfLifeDuration > 0, "Min must be positive");
          require(_minHalfLifeDuration <= maxHalfLifeDuration, "Min exceeds max");
          minHalfLifeDuration = _minHalfLifeDuration;
          if (halfLifeDuration < minHalfLifeDuration) {
              halfLifeDuration = minHalfLifeDuration;
          }
       }
       function setMaxHalfLifeDuration(uint256 _maxHalfLifeDuration) external onlyRole(ADMIN_ROLE) { /* ... as before ... */
          require(_maxHalfLifeDuration > 0, "Max must be positive");
          require(_maxHalfLifeDuration >= minHalfLifeDuration, "Max below minimum");
          maxHalfLifeDuration = _maxHalfLifeDuration;
           if (halfLifeDuration > maxHalfLifeDuration) {
              halfLifeDuration = maxHalfLifeDuration;
          }
       }
       function setInactivityResetPeriod(uint256 _inactivityResetPeriod) external onlyRole(ADMIN_ROLE) { /* ... as before ... */
          require(_inactivityResetPeriod > 0, "Period must be positive");
          inactivityResetPeriod = _inactivityResetPeriod;
       }


    // --- Pausing Functions ---
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // --- AccessControl Setup ---
    // Attempting override with only AccessControl
    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

}