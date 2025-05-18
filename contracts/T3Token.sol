// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Using Upgradeable OpenZeppelin Contracts
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol"; 
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";


/**
 * @title T3Token (T3USD) - Upgradeable Version with Pre-funded Stablecoin Fee Logic
 * @dev Refactored to prevent stack too deep errors.
 */
contract T3Token is Initializable, ERC20PausableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // --- Fee Structure Constants ---
    uint256 private constant BASIS_POINTS = 10000; 
    uint256 private constant FEE_PRECISION_MULTIPLIER = 1000; 
    uint256 private constant EFFECTIVE_BASIS_POINTS = BASIS_POINTS * FEE_PRECISION_MULTIPLIER; 
    uint256 private constant TIER_MULTIPLIER = 10; 
    uint256 private constant MIN_FEE_WEI = 10**13;
    uint256 private constant MAX_FEE_PERCENT_BPS = 1000;
    uint256 private constant BASE_RISK_SCALER_BPS = 1;
    uint256 private constant MAX_RISK_SCALER_BPS = BASIS_POINTS;

    // --- HalfLife Constants ---
    uint256 public halfLifeDuration; 
    uint256 public minHalfLifeDuration; 
    uint256 public maxHalfLifeDuration; 
    uint256 public inactivityResetPeriod; 

    // --- Addresses ---
    address public treasuryAddress;

    // --- Data Structures ---
    struct TransferMetadata {
        uint256 commitWindowEnd;
        uint256 halfLifeDuration;
        address originator;
        uint256 transferCount;
        bytes32 reversalHash;
        uint256 totalFeeAssessed; 
        bool isReversed;
    }
    struct RollingAverage { 
        uint256 totalAmount;
        uint256 count;
        uint256 lastUpdated;
    }
    struct WalletRiskProfile { 
        uint256 reversalCount;
        uint256 lastReversal;
        uint256 creationTime;
        uint256 abnormalTxCount;
    }
    struct IncentiveCredits { 
        uint256 amount;
        uint256 lastUpdated;
    }
    struct FeeDetails { 
        uint256 requestedAmount; 
        uint256 baseFeeAmount;
        uint256 senderRiskScore;
        uint256 recipientRiskScore;
        uint256 applicableRiskScore;
        uint256 amountRiskScaler;
        uint256 scaledRiskImpactBps;
        uint256 finalRiskFactorBps;
        uint256 feeBeforeCreditsAndBounds; 
        uint256 availableCredits;
        uint256 creditsToApply; 
        uint256 feeAfterCredits;  
        uint256 maxFeeBound;
        uint256 minFeeBound;
        bool maxFeeApplied;
        bool minFeeApplied;
        uint256 totalFeeAssessed; 
        uint256 netAmountToSendToRecipient; 
    }

    // --- Mappings ---
    mapping(address => TransferMetadata) public transferData;
    mapping(address => RollingAverage) public rollingAverages;
    mapping(address => mapping(address => uint256)) public transactionCountBetween;
    mapping(address => WalletRiskProfile) public walletRiskProfiles;
    mapping(address => IncentiveCredits) public incentiveCredits;
    mapping(address => uint256) public mintedByMinter;
    mapping(address => mapping(address => uint256)) public interbankLiability;
    mapping(address => uint256) public prefundedFeeBalances; 

    // --- Events ---
     event TransferWithFee(
        address indexed from,
        address indexed to,
        uint256 amountSentToRecipient,
        uint256 totalFeeAssessed,
        uint256 feePaidFromBalance,
        uint256 feePaidFromPrefund,
        uint256 feePaidFromCredits
    );
     event TransferReversed(address indexed from, address indexed to, uint256 amount);
     event HalfLifeExpired(address indexed wallet, uint256 timestamp);
     event LoyaltyRefundProcessed(address indexed wallet, uint256 amount);
     event RiskFactorUpdated(address indexed wallet, uint256 newRiskFactor); 
     event InterbankLiabilityRecorded(address indexed debtor, address indexed creditor, uint256 amount);
     event InterbankLiabilityCleared(address indexed debtor, address indexed creditor, uint256 amountCleared);
     event TokensMinted(address indexed minter, address indexed recipient, uint256 amount);
     event FeePrefunded(address indexed user, uint256 amount); 
     event PrefundedFeeWithdrawn(address indexed user, uint256 amount); 
     event PrefundedFeeUsed(address indexed user, uint256 amountUsed); 
     event IncentiveCreditUsed(address indexed user, uint256 amountUsed); 


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name,
        string memory symbol,
        address initialAdmin,
        address _treasuryAddress,
        uint256 initialMintAmount,
        uint256 _initialHalfLifeDuration,
        uint256 _initialMinHalfLifeDuration,
        uint256 _initialMaxHalfLifeDuration,
        uint256 _initialInactivityResetPeriod
    ) public initializer {
        __ERC20_init(name, symbol);
        __ERC20Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init(); 

        require(_treasuryAddress != address(0), "Treasury address cannot be zero");
        treasuryAddress = _treasuryAddress;

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);

        if (initialMintAmount > 0) {
            super._mint(initialAdmin, initialMintAmount);
        }

        halfLifeDuration = _initialHalfLifeDuration;
        minHalfLifeDuration = _initialMinHalfLifeDuration;
        maxHalfLifeDuration = _initialMaxHalfLifeDuration;
        inactivityResetPeriod = _initialInactivityResetPeriod;
        require(minHalfLifeDuration > 0, "Min HalfLife must be positive");
        require(minHalfLifeDuration <= maxHalfLifeDuration, "Min HalfLife exceeds max");
        require(halfLifeDuration >= minHalfLifeDuration && halfLifeDuration <= maxHalfLifeDuration, "Initial HalfLife out of bounds");
        require(inactivityResetPeriod > 0, "Inactivity period must be positive");

        if(initialAdmin != address(0)) {
            walletRiskProfiles[initialAdmin].creationTime = block.timestamp;
        }
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(ADMIN_ROLE)
    {
        // Intentionally empty
    }

    // --- Fee Pre-funding Functions ---

    function prefundFees(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "Prefund amount must be positive");
        address sender = _msgSender();
        
        super._transfer(sender, treasuryAddress, amount); 
        prefundedFeeBalances[sender] += amount;

        emit FeePrefunded(sender, amount);
    }

    function withdrawPrefundedFees(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "Withdraw amount must be positive");
        address sender = _msgSender();
        require(prefundedFeeBalances[sender] >= amount, "Insufficient pre-funded balance");
        
        prefundedFeeBalances[sender] -= amount;
        super._transfer(treasuryAddress, sender, amount); 

        emit PrefundedFeeWithdrawn(sender, amount);
    }

    // --- Transfer Logic ---

    function transfer(address recipient, uint256 amountIntendedForRecipient) public virtual override whenNotPaused returns (bool) {
        address sender = _msgSender();
        _ensureProfileExists(sender); 
        _ensureProfileExists(recipient);
        _transferWithT3Logic(sender, recipient, amountIntendedForRecipient);
        return true;
    }

    function transferFrom(address from, address to, uint256 amountIntendedForRecipient) public virtual override whenNotPaused returns (bool) {
        address spender = _msgSender();
        // Allowance must cover amountIntendedForRecipient + any feePaidFromBalanceNow from 'from' account
        // The _handleFeePaymentAndTransfers will check the final balance of 'from'
        // _spendAllowance only checks for amountIntendedForRecipient here.
        // If fee is paid from balance, the super._transfer inside _handleFeePaymentAndTransfers will fail if allowance is insufficient for that part.
        _spendAllowance(from, spender, amountIntendedForRecipient); 
        _ensureProfileExists(from);
        _ensureProfileExists(to);
        _transferWithT3Logic(from, to, amountIntendedForRecipient);
        return true;
    }

    function _calculateTotalFeeAssessed(
        address sender, 
        address recipient, 
        uint256 amountIntendedForRecipient
    ) internal view returns (uint256) {
        uint256 baseFee = calculateBaseFeeAmount(amountIntendedForRecipient);
        uint256 feeAfterRisk = applyRiskAdjustments(baseFee, sender, recipient, amountIntendedForRecipient);
        
        uint256 totalFee = feeAfterRisk; 
        uint256 maxFeeForTx = (amountIntendedForRecipient * MAX_FEE_PERCENT_BPS) / BASIS_POINTS;
        if (totalFee > maxFeeForTx) { totalFee = maxFeeForTx; }

        uint256 minFeeForTx = MIN_FEE_WEI;
        if (totalFee > 0 && totalFee < minFeeForTx && amountIntendedForRecipient >= minFeeForTx) {
             if (minFeeForTx <= maxFeeForTx && minFeeForTx <= amountIntendedForRecipient) {
                  totalFee = minFeeForTx;
             }
        }
        return totalFee;
    }

    function _handleFeePaymentAndTransfers(
        address sender,
        address recipient,
        uint256 amountIntendedForRecipient,
        uint256 totalFeeAssessed
    ) internal returns (uint256 feePaidFromPrefund, uint256 feePaidFromCredits, uint256 feePaidFromBalance) {
        uint256 remainingFeeToCover = totalFeeAssessed;

        if (remainingFeeToCover > 0 && prefundedFeeBalances[sender] > 0) {
            uint256 takeFromPrefund = (remainingFeeToCover < prefundedFeeBalances[sender]) ? remainingFeeToCover : prefundedFeeBalances[sender];
            prefundedFeeBalances[sender] -= takeFromPrefund;
            feePaidFromPrefund = takeFromPrefund;
            remainingFeeToCover -= takeFromPrefund;
            if (takeFromPrefund > 0) emit PrefundedFeeUsed(sender, takeFromPrefund);
        }

        if (remainingFeeToCover > 0) {
            (uint256 feeAfterCreditsApplied, uint256 creditsApplied) = applyCredits(sender, remainingFeeToCover);
            feePaidFromCredits = creditsApplied;
            feePaidFromBalance = feeAfterCreditsApplied; 
            if (creditsApplied > 0) emit IncentiveCreditUsed(sender, creditsApplied);
        }

        uint256 totalCostToSenderFromBalance = amountIntendedForRecipient + feePaidFromBalance;
        uint256 senderCurrentBalance = balanceOf(sender); 
        if (senderCurrentBalance < totalCostToSenderFromBalance) {
            revert ERC20InsufficientBalance(sender, senderCurrentBalance, totalCostToSenderFromBalance);
        }

        if (feePaidFromBalance > 0) {
            super._transfer(sender, treasuryAddress, feePaidFromBalance);
        }

        if (amountIntendedForRecipient > 0) { 
            super._transfer(sender, recipient, amountIntendedForRecipient);
        }
        return (feePaidFromPrefund, feePaidFromCredits, feePaidFromBalance);
    }
    
    function _updatePostTransferMetadata(
        address sender,
        address recipient,
        uint256 amountIntendedForRecipient,
        uint256 finalTotalFeeAssessed
    ) internal {
        transactionCountBetween[sender][recipient]++; 
        uint256 adaptiveHalfLife = calculateAdaptiveHalfLife(sender, recipient, amountIntendedForRecipient);

        transferData[recipient] = TransferMetadata({
            commitWindowEnd: block.timestamp + adaptiveHalfLife,
            halfLifeDuration: adaptiveHalfLife,
            originator: sender,
            transferCount: transferData[recipient].transferCount + 1,
            reversalHash: keccak256(abi.encodePacked(sender, recipient, amountIntendedForRecipient)),
            totalFeeAssessed: finalTotalFeeAssessed,
            isReversed: false
        });
        updateRollingAverage(recipient, amountIntendedForRecipient);
    }


    function _transferWithT3Logic(address sender, address recipient, uint256 amountIntendedForRecipient) internal {
        require(recipient != address(0), "Transfer to zero address");
        require(amountIntendedForRecipient > 0, "Transfer amount must be greater than zero");

        if (transferData[sender].commitWindowEnd > block.timestamp &&
            transferData[sender].originator != recipient) {
            revert("Cannot transfer during HalfLife period except back to originator");
        }

        uint256 totalFeeAssessedForTx = _calculateTotalFeeAssessed(sender, recipient, amountIntendedForRecipient);

        (
            uint256 feePaidFromPrefund,
            uint256 feePaidFromCredits,
            uint256 feePaidFromBalanceNow
        ) = _handleFeePaymentAndTransfers(sender, recipient, amountIntendedForRecipient, totalFeeAssessedForTx);
        
        if (totalFeeAssessedForTx > 0) {
            processFee(sender, recipient, totalFeeAssessedForTx); 
        }

        _updatePostTransferMetadata(sender, recipient, amountIntendedForRecipient, totalFeeAssessedForTx);
        
        emit TransferWithFee(
            sender,
            recipient,
            amountIntendedForRecipient,
            totalFeeAssessedForTx,
            feePaidFromBalanceNow,
            feePaidFromPrefund,
            feePaidFromCredits
        );
    }
    
    function processFee(address sender, address recipient, uint256 totalFeeAssessedForCreditAllocation) internal {
        if (totalFeeAssessedForCreditAllocation == 0) {
            return;
        }
        uint256 senderCreditShare = totalFeeAssessedForCreditAllocation / 4; 
        uint256 recipientCreditShare = totalFeeAssessedForCreditAllocation / 4; 

        if (senderCreditShare > 0) {
            incentiveCredits[sender].amount += senderCreditShare;
            incentiveCredits[sender].lastUpdated = block.timestamp;
        }
        if (recipientCreditShare > 0) {
            incentiveCredits[recipient].amount += recipientCreditShare;
            incentiveCredits[recipient].lastUpdated = block.timestamp;
        }
    }

    function calculateBaseFeeAmount(uint256 amount) internal pure returns (uint256) {
        if (amount == 0) return 0;
        uint256 totalFee = 0;
        uint256[2][] memory tiers = new uint256[2][](11);
        uint256 scale = FEE_PRECISION_MULTIPLIER;

        tiers[0] = [uint256(0.01 * 10**18), uint256(100000 * scale)];
        tiers[1] = [uint256(0.10 * 10**18), uint256(10000 * scale)];
        tiers[2] = [uint256(1.00 * 10**18), uint256(1000 * scale)];
        tiers[3] = [uint256(10.0 * 10**18), uint256(100 * scale)];
        tiers[4] = [uint256(100.0 * 10**18), uint256(10 * scale)];
        tiers[5] = [uint256(1000.0 * 10**18), uint256(1 * scale)];
        tiers[6] = [uint256(10000.0 * 10**18), uint256((1 * scale) / 10)]; 
        tiers[7] = [uint256(100000.0 * 10**18), uint256((1 * scale) / 100)];
        tiers[8] = [uint256(1000000.0 * 10**18), uint256((1 * scale) / 1000)];
        tiers[9] = [type(uint256).max, uint256((1 * scale) / 10000)];
        tiers[10] = [type(uint256).max, uint256((1 * scale) / 100000)];

        for (uint i = 0; i < tiers.length; i++) {
            uint256 tierCeiling = tiers[i][0];
            uint256 scaledTierRateBps = tiers[i][1];
            uint256 tierFloor = (i == 0) ? 0 : tiers[i-1][0];
            uint256 amountInTier = 0;
            if (amount > tierFloor) {
                if (amount >= tierCeiling) {
                    if (tierCeiling > tierFloor) {
                         amountInTier = tierCeiling - tierFloor;
                    } else { 
                         amountInTier = 0;
                         if (tierCeiling == type(uint256).max && i > 0 && tiers[i-1][0] == type(uint256).max) {
                             break;
                         }
                    }
                } else {
                    amountInTier = amount - tierFloor;
                }
            }

            if (amountInTier > 0 && scaledTierRateBps > 0) {
                totalFee += (amountInTier * scaledTierRateBps) / EFFECTIVE_BASIS_POINTS;
            }
            if (amount < tierCeiling) break;
        }
        return totalFee;
    }

   function calculateAmountRiskScaler(uint256 amount) internal view returns (uint256) {
         if (amount == 0) return 0;
         uint256 _tokenDecimals = decimals(); 
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

    function applyRiskAdjustments(
        uint256 baseFeeAmount,
        address sender,
        address recipient,
        uint256 amount 
    ) internal view returns (uint256 feeAfterRisk) {
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
         feeAfterRisk = (baseFeeAmount * finalRiskFactorBps) / BASIS_POINTS;
         return feeAfterRisk;
    }

    function calculateRiskFactor(address wallet) public view returns (uint256) {
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

     function applyCredits(address wallet, uint256 feeToCover) internal returns (uint256 remainingFeeAfterCredits, uint256 creditsActuallyUsed) {
          IncentiveCredits storage credits = incentiveCredits[wallet];
          if (credits.amount == 0 || feeToCover == 0) {
              return (feeToCover, 0);
          }
          if (credits.amount >= feeToCover) {
              creditsActuallyUsed = feeToCover;
              credits.amount -= feeToCover; 
              credits.lastUpdated = block.timestamp;
              remainingFeeAfterCredits = 0;
              return (remainingFeeAfterCredits, creditsActuallyUsed);
          } else { 
              creditsActuallyUsed = credits.amount;
              remainingFeeAfterCredits = feeToCover - credits.amount; 
              credits.amount = 0;
              credits.lastUpdated = block.timestamp;
              return (remainingFeeAfterCredits, creditsActuallyUsed);
          }
     }

    function calculateAdaptiveHalfLife(address sender, address recipient, uint256 amount) internal view returns (uint256) {
         uint256 currentHalfLife = halfLifeDuration; 
         uint256 txCount = transactionCountBetween[sender][recipient];
         if (txCount > 0) {
             uint256 reductionPercent = (txCount * 10 > 90) ? 90 : txCount * 10;
             currentHalfLife = currentHalfLife * (100 - reductionPercent) / 100;
         }
         RollingAverage storage avg = rollingAverages[sender];
         if (avg.count > 0 && avg.totalAmount > 0) { 
             uint256 avgAmount = avg.totalAmount / avg.count;
             if (amount > avgAmount * 10) { 
                 uint256 doubledDuration = currentHalfLife * 2;
                 if (currentHalfLife <= type(uint256).max / 2) {
                    currentHalfLife = doubledDuration;
                 } else {
                    currentHalfLife = type(uint256).max; 
                 }
             }
         }
         if (currentHalfLife < minHalfLifeDuration) { currentHalfLife = minHalfLifeDuration; }
         else if (currentHalfLife > maxHalfLifeDuration) { currentHalfLife = maxHalfLifeDuration; }
         return currentHalfLife;
    }

    function updateRollingAverage(address wallet, uint256 amount) internal {
         RollingAverage storage avg = rollingAverages[wallet];
         if (avg.lastUpdated > 0 && block.timestamp - avg.lastUpdated > inactivityResetPeriod) {
             avg.totalAmount = 0;
             avg.count = 0;
         }
         avg.totalAmount += amount;
         avg.count++;
         avg.lastUpdated = block.timestamp;
    }

    function updateWalletRiskProfileOnReversal(address wallet) internal {
         _ensureProfileExistsForWrite(wallet);
         WalletRiskProfile storage profile = walletRiskProfiles[wallet];
         profile.reversalCount++;
         profile.lastReversal = block.timestamp;
    }

    function _ensureProfileExists(address wallet) internal view {
        // View function, no state change
    }

    function _ensureProfileExistsForWrite(address wallet) internal {
         if (wallet != address(0) && walletRiskProfiles[wallet].creationTime == 0) {
             walletRiskProfiles[wallet].creationTime = block.timestamp;
         }
    }

    // --- Reversal & Expiry Functions ---
     function reverseTransfer(address recipientOfOriginalTransfer, uint256 amountToReverse) external whenNotPaused {
        address originatorOfOriginalTransfer = _msgSender(); 
        TransferMetadata storage meta = transferData[recipientOfOriginalTransfer]; 

        require(meta.originator == originatorOfOriginalTransfer, "Reversal: Sender mismatch");
        require(meta.commitWindowEnd > 0, "Reversal: No active transfer"); 
        require(block.timestamp < meta.commitWindowEnd, "Reversal: HalfLife expired");
        require(!meta.isReversed, "Reversal: Transfer already reversed");
        
        require(balanceOf(recipientOfOriginalTransfer) >= amountToReverse, "Reversal: Insufficient recipient balance for reversal amount");

        meta.isReversed = true;
        updateWalletRiskProfileOnReversal(originatorOfOriginalTransfer); 
        updateWalletRiskProfileOnReversal(recipientOfOriginalTransfer); 

        super._transfer(recipientOfOriginalTransfer, originatorOfOriginalTransfer, amountToReverse);
        emit TransferReversed(originatorOfOriginalTransfer, recipientOfOriginalTransfer, amountToReverse);
     }

     function checkHalfLifeExpiry(address wallet) external whenNotPaused {
        TransferMetadata storage meta = transferData[wallet]; 
        require(meta.commitWindowEnd > 0, "Expiry: No active transfer data");
        require(!meta.isReversed, "Expiry: Transfer was reversed");
        require(block.timestamp >= meta.commitWindowEnd, "Expiry: HalfLife not expired yet");

        uint256 feeAssessedForOriginalTx = meta.totalFeeAssessed; 
        if (feeAssessedForOriginalTx > 0) {
            uint256 totalRefundAmount = feeAssessedForOriginalTx / 8;
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
    function getAvailableCredits(address wallet) external view returns (uint256) {
        return incentiveCredits[wallet].amount;
     }
    function getPrefundedFeeBalance(address wallet) external view returns (uint256) {
        return prefundedFeeBalances[wallet];
    }

    function estimateTransferFeeDetails(
        address sender,
        address recipient,
        uint256 amountIntendedForRecipient 
    ) external view returns (FeeDetails memory details) {
        require(recipient != address(0), "Estimate: Transfer to zero address");
        require(amountIntendedForRecipient > 0, "Estimate: Transfer amount must be greater than zero");

        details.requestedAmount = amountIntendedForRecipient;

        uint256 baseFee = calculateBaseFeeAmount(amountIntendedForRecipient);
        uint256 feeAfterRiskCalc = applyRiskAdjustments(baseFee, sender, recipient, amountIntendedForRecipient);
        
        details.totalFeeAssessed = feeAfterRiskCalc; 
        details.maxFeeBound = (amountIntendedForRecipient * MAX_FEE_PERCENT_BPS) / BASIS_POINTS;
        if (details.totalFeeAssessed > details.maxFeeBound) { 
            details.totalFeeAssessed = details.maxFeeBound; 
            details.maxFeeApplied = true;
        } else {
            details.maxFeeApplied = false; 
        }

        details.minFeeBound = MIN_FEE_WEI;
        if (details.totalFeeAssessed > 0 && details.totalFeeAssessed < details.minFeeBound && amountIntendedForRecipient >= details.minFeeBound) {
             if (details.minFeeBound <= details.maxFeeBound && details.minFeeBound <= amountIntendedForRecipient) { 
                  details.totalFeeAssessed = details.minFeeBound; 
                  details.minFeeApplied = true;
                  if (details.totalFeeAssessed >= details.maxFeeBound) { 
                      details.maxFeeApplied = true; 
                  } else {
                      details.maxFeeApplied = false;
                  }
             } else {
                 details.minFeeApplied = false; 
             }
        } else {
             details.minFeeApplied = false; 
        }
        
        details.feeBeforeCreditsAndBounds = feeAfterRiskCalc; 

        IncentiveCredits storage credits = incentiveCredits[sender];
        details.availableCredits = credits.amount;
        uint256 feeRemainingAfterCredits;

        if (details.availableCredits == 0 || details.totalFeeAssessed == 0) {
             details.creditsToApply = 0;
             feeRemainingAfterCredits = details.totalFeeAssessed;
        } else if (details.availableCredits >= details.totalFeeAssessed) {
             details.creditsToApply = details.totalFeeAssessed;
             feeRemainingAfterCredits = 0;
        } else {
             details.creditsToApply = details.availableCredits;
             feeRemainingAfterCredits = details.totalFeeAssessed - details.availableCredits;
        }
        details.feeAfterCredits = feeRemainingAfterCredits; 
        
        details.netAmountToSendToRecipient = amountIntendedForRecipient; 

        return details;
    }

    // --- Minting and Burning Functions ---
     function mint(address recipient, uint256 amount) external whenNotPaused onlyRole(MINTER_ROLE) {
         require(recipient != address(0), "Mint to the zero address");
         require(amount > 0, "Mint amount must be positive");
         address minterAccount = _msgSender();
         super._mint(recipient, amount); 
         mintedByMinter[minterAccount] += amount;
         _ensureProfileExistsForWrite(recipient);
         emit TokensMinted(minterAccount, recipient, amount);
      }

      function burn(uint256 amount) external whenNotPaused {
          require(amount > 0, "Burn amount must be positive");
          super._burn(_msgSender(), amount); 
       }

       function burnFrom(address account, uint256 amount) external whenNotPaused {
           require(amount > 0, "Burn amount must be positive");
           address spender = _msgSender();
           _spendAllowance(account, spender, amount); 
           super._burn(account, amount); 
       }

    // --- Interbank Liability Functions (Unchanged) ---
     function recordInterbankLiability(address debtor, address creditor, uint256 amount) external onlyRole(ADMIN_ROLE) {
         require(debtor != address(0), "Debtor cannot be zero address");
         require(creditor != address(0), "Creditor cannot be zero address");
         require(debtor != creditor, "Debtor cannot be creditor");
         require(amount > 0, "Amount must be positive");
         interbankLiability[debtor][creditor] += amount;
         emit InterbankLiabilityRecorded(debtor, creditor, amount);
      }
      function clearInterbankLiability(address debtor, address creditor, uint256 amountToClear) external onlyRole(ADMIN_ROLE) {
         require(debtor != address(0), "Debtor cannot be zero address");
         require(creditor != address(0), "Creditor cannot be zero address");
         require(debtor != creditor, "Debtor cannot be creditor");
         require(amountToClear > 0, "Amount to clear must be positive");
         uint256 currentLiability = interbankLiability[debtor][creditor];
         require(amountToClear <= currentLiability, "Amount to clear exceeds outstanding liability");
         interbankLiability[debtor][creditor] = currentLiability - amountToClear;
         emit InterbankLiabilityCleared(debtor, creditor, amountToClear);
      }

    // --- Admin / Role Management Functions (Unchanged) ---
     function flagAbnormalTransaction(address wallet) external onlyRole(ADMIN_ROLE) {
         _ensureProfileExistsForWrite(wallet);
         walletRiskProfiles[wallet].abnormalTxCount++;
      }
      function setTreasuryAddress(address _treasuryAddress) external onlyRole(ADMIN_ROLE) {
          require(_treasuryAddress != address(0), "Treasury address cannot be zero");
          treasuryAddress = _treasuryAddress;
       }
       function setHalfLifeDuration(uint256 _halfLifeDuration) external onlyRole(ADMIN_ROLE) {
          require(_halfLifeDuration >= minHalfLifeDuration, "Below minimum");
          require(_halfLifeDuration <= maxHalfLifeDuration, "Above maximum");
          halfLifeDuration = _halfLifeDuration;
       }
       function setMinHalfLifeDuration(uint256 _minHalfLifeDuration) external onlyRole(ADMIN_ROLE) {
          require(_minHalfLifeDuration > 0, "Min must be positive");
          require(_minHalfLifeDuration <= maxHalfLifeDuration, "Min exceeds max");
          minHalfLifeDuration = _minHalfLifeDuration;
          if (halfLifeDuration < minHalfLifeDuration) {
              halfLifeDuration = minHalfLifeDuration;
          }
       }
       function setMaxHalfLifeDuration(uint256 _maxHalfLifeDuration) external onlyRole(ADMIN_ROLE) {
          require(_maxHalfLifeDuration > 0, "Max must be positive");
          require(_maxHalfLifeDuration >= minHalfLifeDuration, "Max below minimum");
          maxHalfLifeDuration = _maxHalfLifeDuration;
           if (halfLifeDuration > maxHalfLifeDuration) {
              halfLifeDuration = maxHalfLifeDuration;
          }
       }
       function setInactivityResetPeriod(uint256 _inactivityResetPeriod) external onlyRole(ADMIN_ROLE) {
          require(_inactivityResetPeriod > 0, "Period must be positive");
          inactivityResetPeriod = _inactivityResetPeriod;
       }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause(); 
    }
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause(); 
    }

    // --- Access Control Functions ---

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlUpgradeable)
        returns (bool)
    {
        // ERC165 (0x01ffc9a7), AccessControl (0x7965db0b), ERC20 (0x36372b07)
        if (
            interfaceId == 0x01ffc9a7 || // ERC165
            interfaceId == 0x7965db0b || // IAccessControl
            interfaceId == 0x36372b07    // IERC20
        ) {
            return true;
        }
        return super.supportsInterface(interfaceId);
    }

}
