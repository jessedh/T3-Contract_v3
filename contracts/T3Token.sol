// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Using Upgradeable OpenZeppelin Contracts
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

// Import Custom CustodianRegistry
import "./CustodianRegistry.sol"; // Assuming CustodianRegistry.sol is in the same directory
// Import the new Fee Calculation Library
import "./FeeCalculationLibrary.sol";
// Import the interface for the new Locked Transfer Manager
import "interfaces/ILockedTransferManager.sol";
// NEW: Import the interface for the new Interbank Liability Ledger
import "interfaces/IInterbankLiabilityLedger.sol";

/**
 * @title T3Token (T3USD) - Upgradeable Version with Pre-funded Stablecoin Fee Logic
 * @dev Refactored to prevent stack too deep errors.
 * Now includes Time-Locked Transfers (managed by external contract) and integrates with CustodianRegistry for compliance.
 */
contract T3Token is Initializable, ERC20PausableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {

    // --- Custom Errors ---
    error ErrorZeroAddress();
    error ErrorAmountZero();
    error ErrorInsufficientPrefundedBalance();
    error ErrorSenderNotRegistered();
    error ErrorRecipientNotRegistered();
    error ErrorSpenderNotRegistered();
    error ErrorAccountNotRegistered();
    // Removed specific Interbank Liability errors as they are now in the Ledger contract
    // error ErrorDebtorNotRegistered();
    // error ErrorCreditorNotRegistered();
    // error ErrorDebtorNotCustodian();
    // error ErrorCreditorNotCustodian();
    // error ErrorDebtorIsCreditor();
    // error ErrorAmountToClearExceedsLiability();
    error ErrorHalfLifeActive();
    error ErrorHalfLifeExpired();
    error ErrorHalfLifeNotExpired();
    error ErrorNoActiveTransfer();
    error ErrorTransferReversed();
    error ErrorTransferFinalized();
    error ErrorSenderMismatch();
    error ErrorInsufficientRecipientBalance();
    error ErrorTreasuryAddressZero();
    error ErrorMinHalfLifePositive();
    error ErrorMinHalfLifeExceedsMax();
    error ErrorInitialHalfLifeOutOfBounds();
    error ErrorInactivityPeriodPositive();
    error ErrorBelowMinimumHalfLife();
    error ErrorAboveMaximumHalfLife();
    error ErrorMaxHalfLifePositive();
    error ErrorMaxHalfLifeBelowMinimum();


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
    uint256 private constant MIN_FEE_WEI = 10**13; // 0.01 T3 (assuming 18 decimals)
    uint256 private constant MAX_FEE_PERCENT_BPS = 1000; // 10%
    uint256 private constant BASE_RISK_SCALER_BPS = 1; // 0.01% per tier base
    uint256 private constant MAX_RISK_SCALER_BPS = BASIS_POINTS; // 100% max scaler

    // --- HalfLife Constants ---
    uint256 public halfLifeDuration;
    uint256 public minHalfLifeDuration;
    uint256 public maxHalfLifeDuration;
    uint256 public inactivityResetPeriod;

    // --- Addresses ---
    address public treasuryAddress;
    CustodianRegistry public custodianRegistry; // NEW: Reference to CustodianRegistry
    ILockedTransferManager public lockedTransferManager; // NEW: Reference to the external LockedTransferManager
    IInterbankLiabilityLedger public interbankLiabilityLedger; // NEW: Reference to the external InterbankLiabilityLedger

    // --- Data Structures ---
    // Original TransferMetadata struct (for sender's HalfLife tracking - from previous template)
    struct TransferMetadata {
        uint256 commitWindowEnd;
        uint256 halfLifeDuration;
        address originator;
        uint256 transferCount;
        bytes32 reversalHash;
        uint256 totalFeeAssessed;
        bool isReversed;
    }
    // NEW: HalfLifeTransfer struct (for recipient's pending funds as per patent)
    struct HalfLifeTransfer {
        address sender; // Original sender of the pending amount
        uint256 amount; // Amount currently pending for the recipient
        uint256 expiryTimestamp;
        bool reversed;
        bool finalized;
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
        uint224 finalRiskFactorBps; // Changed to uint224 to save slot
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

    // Removed LockedTransfer struct and associated mappings/events from here
    // as they are now in LockedTransferManager.sol
    // struct LockedTransfer { ... }
    // mapping(bytes32 => LockedTransfer) public lockedTransfers;
    // uint256 private nextLockedTransferId;


    // --- Mappings ---
    mapping(address => TransferMetadata) public transferData; // Original sender-side HalfLife tracking (from template)
    mapping(address => HalfLifeTransfer) public pendingHalfLifeTransfers; // NEW: Recipient-side HalfLife tracking
    mapping(address => RollingAverage) public rollingAverages;
    mapping(address => mapping(address => uint256)) public transactionCountBetween;
    mapping(address => WalletRiskProfile) public walletRiskProfiles;
    mapping(address => IncentiveCredits) public incentiveCredits;
    mapping(address => uint256) public mintedByMinter;
    // Removed interbankLiability mapping as it's now in InterbankLiabilityLedger.sol
    // mapping(address => mapping(address => uint256)) public interbankLiability;
    // FIXED: Declared prefundedFeeBalances mapping
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
    event HalfLifeExpired(address indexed wallet, uint256 timestamp); // For sender-side HalfLife
    event LoyaltyRefundProcessed(address indexed wallet, uint256 amount);
    event RiskFactorUpdated(address indexed wallet, uint256 newRiskFactor);
    // Removed InterbankLiability events as they are now in InterbankLiabilityLedger.sol
    // event InterbankLiabilityRecorded(address indexed debtor, address indexed creditor, uint256 amount);
    // event InterbankLiabilityCleared(address indexed debtor, address indexed creditor, uint256 amountCleared);
    event TokensMinted(address indexed minter, address indexed recipient, uint256 amount);
    event FeePrefunded(address indexed user, uint256 amount);
    event PrefundedFeeWithdrawn(address indexed user, uint256 amount);
    event PrefundedFeeUsed(address indexed user, uint256 amountUsed);
    event IncentiveCreditUsed(address indexed user, uint256 amountUsed);

    // Removed LockedTransfer events from here as they are now in LockedTransferManager.sol
    // event LockedTransferCreated(bytes32 indexed transferId, address indexed sender, address indexed recipient, uint256 amount, address releaseAuthorizedAddress);
    // event LockedTransferReleased(bytes32 indexed transferId, address indexed recipient, uint256 amount);
    // event LockedTransferCancelled(bytes32 indexed transferId);

    // NEW: Events for Recipient HalfLife
    event RecipientTransferPending(address indexed sender, address indexed recipient, uint256 amount, uint256 expiryTimestamp);
    event RecipientTransferReversed(address indexed sender, address indexed recipient, uint256 amount);
    event RecipientTransferFinalized(address indexed sender, address indexed recipient, uint256 amount);


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name,
        string memory symbol,
        address initialAdmin,
        address _treasuryAddress,
        address _custodianRegistryAddress, // NEW: CustodianRegistry address
        address _lockedTransferManagerAddress, // NEW: LockedTransferManager address
        address _interbankLiabilityLedgerAddress, // NEW: InterbankLiabilityLedger address
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

        if (_treasuryAddress == address(0)) revert ErrorTreasuryAddressZero();
        treasuryAddress = _treasuryAddress;

        // NEW: Initialize CustodianRegistry reference
        if (_custodianRegistryAddress == address(0)) revert ErrorZeroAddress(); // Reusing ErrorZeroAddress
        custodianRegistry = CustodianRegistry(_custodianRegistryAddress);

        // NEW: Initialize LockedTransferManager reference
        if (_lockedTransferManagerAddress == address(0)) revert ErrorZeroAddress(); // Reusing ErrorZeroAddress
        lockedTransferManager = ILockedTransferManager(_lockedTransferManagerAddress);

        // NEW: Initialize InterbankLiabilityLedger reference
        if (_interbankLiabilityLedgerAddress == address(0)) revert ErrorZeroAddress(); // Reusing ErrorZeroAddress
        interbankLiabilityLedger = IInterbankLiabilityLedger(_interbankLiabilityLedgerAddress);


        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);

        if (initialMintAmount > 0) {
            // For bootstrap, assuming initialAdmin is implicitly trusted or will be registered by CustodianRegistry.
            // This mint is outside the standard transfer logic, so no HalfLife or fees apply here.
            _mint(initialAdmin, initialMintAmount);
        }

        halfLifeDuration = _initialHalfLifeDuration;
        minHalfLifeDuration = _initialMinHalfLifeDuration;
        maxHalfLifeDuration = _initialMaxHalfLifeDuration;
        inactivityResetPeriod = _initialInactivityResetPeriod;
        if (minHalfLifeDuration == 0) revert ErrorMinHalfLifePositive();
        if (minHalfLifeDuration > maxHalfLifeDuration) revert ErrorMinHalfLifeExceedsMax();
        if (halfLifeDuration < minHalfLifeDuration || halfLifeDuration > maxHalfLifeDuration) revert ErrorInitialHalfLifeOutOfBounds();
        if (inactivityResetPeriod == 0) revert ErrorInactivityPeriodPositive();

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
        if (amount == 0) revert ErrorAmountZero();
        address sender = _msgSender();
        // NEW: Compliance check for sender using new CustodianRegistry interface
        if (!(custodianRegistry.isKYCValid(sender) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), sender))) revert ErrorSenderNotRegistered();

        super._transfer(sender, treasuryAddress, amount);
        prefundedFeeBalances[sender] += amount;

        emit FeePrefunded(sender, amount);
    }

    function withdrawPrefundedFees(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ErrorAmountZero();
        address sender = _msgSender();
        if (prefundedFeeBalances[sender] < amount) revert ErrorInsufficientPrefundedBalance();
        // NEW: Compliance check for sender using new CustodianRegistry interface
        if (!(custodianRegistry.isKYCValid(sender) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), sender))) revert ErrorSenderNotRegistered();

        prefundedFeeBalances[sender] -= amount;
        super._transfer(treasuryAddress, sender, amount);

        emit PrefundedFeeWithdrawn(sender, amount);
    }

    // --- Transfer Logic ---

    function transfer(address recipient, uint256 amountIntendedForRecipient) public virtual override whenNotPaused returns (bool) {
        address sender = _msgSender();
        // NEW: Compliance check for sender and recipient using new CustodianRegistry interface
        if (!(custodianRegistry.isKYCValid(sender) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), sender))) revert ErrorSenderNotRegistered();
        if (!(custodianRegistry.isKYCValid(recipient) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), recipient))) revert ErrorRecipientNotRegistered();

        _ensureProfileExists(sender);
        _ensureProfileExists(recipient);
        _transferWithT3Logic(sender, recipient, amountIntendedForRecipient);
        return true;
    }

    function transferFrom(address from, address to, uint256 amountIntendedForRecipient) public virtual override whenNotPaused returns (bool) {
        address spender = _msgSender();
        // NEW: Compliance check for from, to, and spender using new CustodianRegistry interface
        if (!(custodianRegistry.isKYCValid(from) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), from))) revert ErrorSenderNotRegistered();
        if (!(custodianRegistry.isKYCValid(to) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), to))) revert ErrorRecipientNotRegistered();
        if (!(custodianRegistry.isKYCValid(spender) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), spender))) revert ErrorSpenderNotRegistered();

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
        // Using library functions
        uint256 baseFee = FeeCalculationLibrary.calculateBaseFeeAmount(amountIntendedForRecipient);
        uint256 feeAfterRisk = applyRiskAdjustments(baseFee, sender, recipient, amountIntendedForRecipient);

        uint256 totalFee = feeAfterRisk;
        uint256 maxFeeForTx = (amountIntendedForRecipient * MAX_FEE_PERCENT_BPS) / BASIS_POINTS;
        if (totalFee > maxFeeForTx) { totalFee = maxFeeForTx; }

        uint256 minFeeForTx = MIN_FEE_WEI;
        if (totalFee > 0 && totalFee < minFeeForTx && amountIntendedForRecipient >= minFeeForTx) {
             if (minFeeForTx <= maxFeeForTx && minFeeForTx <= amountIntendedForRecipient) {
                 totalFee = minFeeForTx;
             } else {
                 // If minFeeForTx is too high or greater than intended amount, don't apply it as a floor.
                 // This scenario means the calculated fee is less than minFeeWei,
                 // but applying minFeeWei would make the fee > maxFeeForTx or > amountIntendedForRecipient.
                 // In such cases, use the calculated fee.
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

        // NEW: Check spendable balance before actual transfer
        uint256 totalCostToSenderFromBalance = amountIntendedForRecipient + feePaidFromBalance;
        uint256 senderSpendableBalance = _spendableBalance(sender);
        if (senderSpendableBalance < totalCostToSenderFromBalance) {
            revert ERC20InsufficientBalance(sender, senderSpendableBalance, totalCostToSenderFromBalance);
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

        // Original sender-side HalfLife tracking (from template)
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

        // NEW: Recipient-side HalfLife tracking (to restrict recipient re-transfers)
        // Auto-finalize any existing pending transfer to this recipient if expired
        _finalizeRecipientHalfLifeTransfer(recipient);

        pendingHalfLifeTransfers[recipient] = HalfLifeTransfer({
            sender: sender, // Original sender of this specific pending amount
            amount: amountIntendedForRecipient, // Net amount received by recipient
            expiryTimestamp: block.timestamp + adaptiveHalfLife,
            reversed: false,
            finalized: false
        });
        emit RecipientTransferPending(sender, recipient, amountIntendedForRecipient, pendingHalfLifeTransfers[recipient].expiryTimestamp);
    }


    function _transferWithT3Logic(address sender, address recipient, uint256 amountIntendedForRecipient) internal {
        if (recipient == address(0)) revert ErrorZeroAddress();
        if (amountIntendedForRecipient == 0) revert ErrorAmountZero();

        // Original HalfLife check: Prevents sender from making new transfers *out* while their *outgoing* HalfLife is active.
        // This check is kept as it was in the provided template.
        if (transferData[sender].commitWindowEnd > block.timestamp &&
            transferData[sender].originator != recipient && // Allows sender to reverse back to originator
            sender != transferData[recipient].originator // Avoids blocking if sender is current recipient of another HalfLife
        ) {
            revert ErrorHalfLifeActive();
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

        // Interbank Liability Logic - now delegated to external contract
        address senderCustodian = custodianRegistry.getCustodian(sender); // Use address directly
        address recipientCustodian = custodianRegistry.getCustodian(recipient); // Use address directly

        if (senderCustodian != address(0) && recipientCustodian != address(0) && senderCustodian != recipientCustodian) {
            // Call the external InterbankLiabilityLedger contract
            interbankLiabilityLedger.recordInterbankLiability(senderCustodian, recipientCustodian, amountIntendedForRecipient);
            // The event is emitted by the ledger contract now
            // emit InterbankLiabilityRecorded(sender, recipient, amountIntendedForRecipient);
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
        // Using library function
        uint256 amountScalerBps = FeeCalculationLibrary.calculateAmountRiskScaler(amount, decimals());
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
        // This function in the provided template is empty, its purpose might be
        // to assert/require wallet validity via an external registry.
        // For this implementation, we will use it as a placeholder to allow
        // the `calculateRiskFactor` to access `walletRiskProfiles[wallet].creationTime` etc.
        // The actual wallet approval (KYC/AML) is handled by custodianRegistry.isWalletApproved.
        if (walletRiskProfiles[wallet].creationTime == 0 && wallet != address(0)) {
            // No-op for view functions, as it's a read-only check.
            // CreationTime is only set on write.
        }
    }

    function _ensureProfileExistsForWrite(address wallet) internal {
        if (wallet != address(0) && walletRiskProfiles[wallet].creationTime == 0) {
            walletRiskProfiles[wallet].creationTime = block.timestamp;
        }
    }

    // --- Recipient HalfLife Functions (NEW) ---

    /**
     * @dev Allows a recipient to reverse a pending HalfLife transfer within the window.
     * Only the recipient can call this.
     */
    function reverseRecipientTransfer() external nonReentrant whenNotPaused {
        HalfLifeTransfer storage pending = pendingHalfLifeTransfers[_msgSender()];
        if (pending.sender == address(0)) revert ErrorNoActiveTransfer();
        if (pending.reversed) revert ErrorTransferReversed();
        if (pending.finalized) revert ErrorTransferFinalized();
        if (block.timestamp >= pending.expiryTimestamp) revert ErrorHalfLifeExpired();

        // Compliance check for recipient and sender
        if (!(custodianRegistry.isKYCValid(_msgSender()) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), _msgSender()))) revert ErrorRecipientNotRegistered();
        if (!(custodianRegistry.isKYCValid(pending.sender) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), pending.sender))) revert ErrorSenderNotRegistered();

        // Transfer tokens back to the original sender
        // Note: This calls the internal _transfer which will check _spendableBalance.
        // The recipient's balance should have the pending amount, so this should succeed.
        super._transfer(_msgSender(), pending.sender, pending.amount);

        pending.reversed = true; // Mark as reversed
        // Do NOT delete immediately, keep for finalization check.
        // delete pendingHalfLifeTransfers[_msgSender()]; // Clear the pending entry

        // Interbank Liability Logic for Reversal - now delegated to external contract
        address senderCustodian = custodianRegistry.getCustodian(pending.sender); // Use address directly
        address recipientCustodian = custodianRegistry.getCustodian(_msgSender()); // Use address directly

        if (senderCustodian != address(0) && recipientCustodian != address(0) && senderCustodian != recipientCustodian) {
            // Call the external InterbankLiabilityLedger contract to clear the liability
            interbankLiabilityLedger.clearInterbankLiability(senderCustodian, recipientCustodian, pending.amount);
            // The event is emitted by the ledger contract now
            // emit InterbankLiabilityCleared(pending.sender, _msgSender(), pending.amount);
        }

        emit RecipientTransferReversed(pending.sender, _msgSender(), pending.amount);
    }

    /**
     * @dev Allows anyone to finalize an expired HalfLife transfer for a given recipient.
     * Also called internally by _updatePostTransferMetadata if a new transfer comes in.
     * This processes the recipient-side HalfLife.
     */
    function finalizeRecipientTransfer(address _recipient) public nonReentrant whenNotPaused {
        HalfLifeTransfer storage pending = pendingHalfLifeTransfers[_recipient];
        if (pending.sender == address(0)) revert ErrorNoActiveTransfer();
        if (pending.finalized) revert ErrorTransferFinalized();
        if (pending.reversed) revert ErrorTransferReversed();
        if (block.timestamp < pending.expiryTimestamp) revert ErrorHalfLifeNotExpired();

        // Compliance check for recipient and sender
        if (!(custodianRegistry.isKYCValid(_recipient) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), _recipient))) revert ErrorRecipientNotRegistered();
        if (!(custodianRegistry.isKYCValid(pending.sender) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), pending.sender))) revert ErrorSenderNotRegistered();

        pending.finalized = true; // Mark as finalized

        // Award incentive credits (from original fee assessed)
        // Note: The original fee for the A->B transfer is stored in transferData[B].totalFeeAssessed
        // However, transferData[B] is for the *sender's* HalfLife (A's HalfLife in A->B)
        // If we want to link this to the fee of the A->B transfer, we need to pass it or look it up.
        // For simplicity, let's use the fee from the original `TransferMetadata` if available for the recipient.
        // The `totalFeeAssessed` in `TransferMetadata` is for the *recipient* of the transfer, not the sender.
        // So `transferData[_recipient].totalFeeAssessed` should be the fee for the A->B transfer.
        uint256 feeAssessedForOriginalTx = transferData[_recipient].totalFeeAssessed;
        if (feeAssessedForOriginalTx > 0) {
            uint256 totalRefundAmount = feeAssessedForOriginalTx / 8; // 12.5% of total fee
            if (totalRefundAmount > 0) {
                uint256 refundPerParty = totalRefundAmount / 2;
                if (refundPerParty > 0) {
                    incentiveCredits[pending.sender].amount += refundPerParty; // Original sender gets credit
                    incentiveCredits[pending.sender].lastUpdated = block.timestamp;
                    emit LoyaltyRefundProcessed(pending.sender, refundPerParty);

                    incentiveCredits[_recipient].amount += refundPerParty; // Recipient gets credit
                    incentiveCredits[_recipient].lastUpdated = block.timestamp;
                    emit LoyaltyRefundProcessed(_recipient, refundPerParty);
                }
            }
        }

        delete pendingHalfLifeTransfers[_recipient]; // Clear the pending entry
        emit RecipientTransferFinalized(pending.sender, _recipient, pending.amount);
    }

    /**
     * @dev Internal helper to finalize a pending recipient transfer if it's expired.
     */
    function _finalizeRecipientHalfLifeTransfer(address _recipient) internal {
        HalfLifeTransfer storage pending = pendingHalfLifeTransfers[_recipient];
        if (pending.sender != address(0) && !pending.finalized && !pending.reversed && block.timestamp >= pending.expiryTimestamp) {
            finalizeRecipientTransfer(_recipient);
        }
    }

    /**
     * @dev Overrides ERC20's `_update` (formerly `_transfer` in older OZ) to enforce spendable balance.
     * This is the core modification to restrict recipient re-transfers during HalfLife.
     */
    function _update(address from, address to, uint256 amount) internal virtual override(ERC20PausableUpgradeable) {
        // Note: The previous override was ERC20PausableUpgradeable. ERC20Upgradeable also has _update.
        // We need to ensure all direct parents implementing _update are in the list.

        // Only apply spendable balance check for actual token holders trying to send.
        // Do not apply for minting (from == address(0)), burning (to == address(0)),
        // or internal transfers (from == address(this) e.g., fees or locked transfers).
        if (from != address(0) && from != address(this)) {
            uint256 spendable = _spendableBalance(from);
            require(spendable >= amount, "ERC20: transfer amount exceeds spendable balance (HalfLife pending)"); // Keep ERC20 error string for standard behavior
        }
        super._update(from, to, amount);
    }

    /**
     * @dev Returns the spendable balance of an account, considering pending HalfLife transfers.
     * This function is crucial for the recipient-side HalfLife restriction.
     */
    function _spendableBalance(address account) internal view returns (uint256) {
        uint256 totalBalance = super.balanceOf(account);
        HalfLifeTransfer storage pending = pendingHalfLifeTransfers[account];

        // If there's a pending transfer to this account that hasn't finalized and isn't expired
        if (pending.sender != address(0) && !pending.finalized && !pending.reversed && block.timestamp < pending.expiryTimestamp) {
            // Subtract the pending amount from the total balance to get spendable
            return totalBalance - pending.amount;
        }
        return totalBalance;
    }

    // --- Reversal & Expiry Functions (Original from template, renamed to avoid confusion) ---
    // These functions refer to the sender's HalfLife (transferData mapping)
    function reverseSenderTransfer(address recipientOfOriginalTransfer, uint256 amountToReverse) external whenNotPaused nonReentrant {
        address originatorOfOriginalTransfer = _msgSender();
        TransferMetadata storage meta = transferData[recipientOfOriginalTransfer];

        // Compliance check for recipientOfOriginalTransfer and originatorOfOriginalTransfer
        if (!(custodianRegistry.isKYCValid(recipientOfOriginalTransfer) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), recipientOfOriginalTransfer))) revert ErrorRecipientNotRegistered();
        if (!(custodianRegistry.isKYCValid(originatorOfOriginalTransfer) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), originatorOfOriginalTransfer))) revert ErrorSenderNotRegistered();

        if (meta.originator != originatorOfOriginalTransfer) revert ErrorSenderMismatch();
        if (meta.commitWindowEnd == 0) revert ErrorNoActiveTransfer();
        if (block.timestamp >= meta.commitWindowEnd) revert ErrorHalfLifeExpired();
        if (meta.isReversed) revert ErrorTransferReversed();

        // This check is for the recipient's current balance, which might include pending funds.
        // This function is for the *sender* to reverse, so it's about the recipient *returning* funds.
        if (balanceOf(recipientOfOriginalTransfer) < amountToReverse) revert ErrorInsufficientRecipientBalance();

        meta.isReversed = true;
        updateWalletRiskProfileOnReversal(originatorOfOriginalTransfer);
        updateWalletRiskProfileOnReversal(recipientOfOriginalTransfer);

        super._transfer(recipientOfOriginalTransfer, originatorOfOriginalTransfer, amountToReverse);
        emit TransferReversed(originatorOfOriginalTransfer, recipientOfOriginalTransfer, amountToReverse);

        // Interbank Liability Logic for Reversal - now delegated to external contract
        address originatorCustodian = custodianRegistry.getCustodian(originatorOfOriginalTransfer); // Use address directly
        address recipientCustodian = custodianRegistry.getCustodian(recipientOfOriginalTransfer); // Use address directly

        if (originatorCustodian != address(0) && recipientCustodian != address(0) && originatorCustodian != recipientCustodian) {
            // Call the external InterbankLiabilityLedger contract to clear the liability
            interbankLiabilityLedger.clearInterbankLiability(originatorCustodian, recipientCustodian, amountToReverse);
            // The event is emitted by the ledger contract now
            // emit InterbankLiabilityCleared(originatorOfOriginalTransfer, recipientOfOriginalTransfer, amountToReverse);
        }
    }

    function checkSenderHalfLifeExpiry(address wallet) external whenNotPaused nonReentrant {
        TransferMetadata storage meta = transferData[wallet];
        if (meta.commitWindowEnd == 0) revert ErrorNoActiveTransfer();
        if (meta.isReversed) revert ErrorTransferReversed();
        if (block.timestamp < meta.commitWindowEnd) revert ErrorHalfLifeNotExpired();

        uint256 feeAssessedForOriginalTx = meta.totalFeeAssessed;
        if (feeAssessedForOriginalTx > 0) {
            uint256 totalRefundAmount = feeAssessedForOriginalTx / 8; // 12.5% of total fee
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
        if (recipient == address(0)) revert ErrorZeroAddress();
        if (amountIntendedForRecipient == 0) revert ErrorAmountZero();

        // NEW: Compliance check for sender and recipient for estimation
        if (!(custodianRegistry.isKYCValid(sender) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), sender))) revert ErrorSenderNotRegistered();
        if (!(custodianRegistry.isKYCValid(recipient) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), recipient))) revert ErrorRecipientNotRegistered();

        details.requestedAmount = amountIntendedForRecipient;

        // Using library function
        uint256 baseFee = FeeCalculationLibrary.calculateBaseFeeAmount(amountIntendedForRecipient);
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

    // NEW: View function for recipient-side HalfLife
    function getPendingRecipientTransfer(address _recipient) public view returns (address sender, uint256 amount, uint256 expiryTimestamp, bool reversed, bool finalized) {
        HalfLifeTransfer storage pending = pendingHalfLifeTransfers[_recipient];
        return (pending.sender, pending.amount, pending.expiryTimestamp, pending.reversed, pending.finalized);
    }

    // NEW: View function for spendable balance
    function getSpendableBalance(address account) public view returns (uint256) {
        return _spendableBalance(account);
    }

    // --- Minting and Burning Functions ---
    function mint(address recipient, uint256 amount) external whenNotPaused onlyRole(MINTER_ROLE) {
        if (recipient == address(0)) revert ErrorZeroAddress();
        if (amount == 0) revert ErrorAmountZero();
        address minterAccount = _msgSender();
        // NEW: Compliance check for recipient
        if (!(custodianRegistry.isKYCValid(recipient) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), recipient))) revert ErrorRecipientNotRegistered();

        super._mint(recipient, amount);
        mintedByMinter[minterAccount] += amount;
        _ensureProfileExistsForWrite(recipient);
        emit TokensMinted(minterAccount, recipient, amount);
    }

    function burn(uint256 amount) external whenNotPaused {
        if (amount == 0) revert ErrorAmountZero();
        // NEW: Compliance check for burner
        if (!(custodianRegistry.isKYCValid(_msgSender()) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), _msgSender()))) revert ErrorSenderNotRegistered(); // Reusing sender not registered error
        super._burn(_msgSender(), amount);
    }

    function burnFrom(address account, uint256 amount) external whenNotPaused {
        if (amount == 0) revert ErrorAmountZero();
        address spender = _msgSender();
        // NEW: Compliance check for account and spender
        if (!(custodianRegistry.isKYCValid(account) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), account))) revert ErrorAccountNotRegistered();
        if (!(custodianRegistry.isKYCValid(spender) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), spender))) revert ErrorSpenderNotRegistered();
        _spendAllowance(account, spender, amount);
        super._burn(account, amount);
    }

    // --- Interbank Liability Functions - NOW EXTERNALIZED ---
    // These functions are removed from T3Token and called on InterbankLiabilityLedger

    // --- Admin / Role Management Functions (Unchanged, except _custodianRegistryAddress in initialize) ---
    function flagAbnormalTransaction(address wallet) external onlyRole(ADMIN_ROLE) {
        _ensureProfileExistsForWrite(wallet);
        walletRiskProfiles[wallet].abnormalTxCount++;
    }
    function setTreasuryAddress(address _treasuryAddress) external onlyRole(ADMIN_ROLE) {
        if (_treasuryAddress == address(0)) revert ErrorTreasuryAddressZero();
        treasuryAddress = _treasuryAddress;
    }
    // NEW: Setter for LockedTransferManager address
    function setLockedTransferManagerAddress(address _lockedTransferManagerAddress) external onlyRole(ADMIN_ROLE) {
        if (_lockedTransferManagerAddress == address(0)) revert ErrorZeroAddress();
        lockedTransferManager = ILockedTransferManager(_lockedTransferManagerAddress);
    }
    // NEW: Setter for InterbankLiabilityLedger address
    function setInterbankLiabilityLedgerAddress(address _interbankLiabilityLedgerAddress) external onlyRole(ADMIN_ROLE) {
        if (_interbankLiabilityLedgerAddress == address(0)) revert ErrorZeroAddress();
        interbankLiabilityLedger = IInterbankLiabilityLedger(_interbankLiabilityLedgerAddress);
    }

    function setHalfLifeDuration(uint256 _halfLifeDuration) external onlyRole(ADMIN_ROLE) {
        if (_halfLifeDuration < minHalfLifeDuration) revert ErrorBelowMinimumHalfLife();
        if (_halfLifeDuration > maxHalfLifeDuration) revert ErrorAboveMaximumHalfLife();
        halfLifeDuration = _halfLifeDuration;
    }
    function setMinHalfLifeDuration(uint256 _minHalfLifeDuration) external onlyRole(ADMIN_ROLE) {
        if (_minHalfLifeDuration == 0) revert ErrorMinHalfLifePositive();
        if (_minHalfLifeDuration > maxHalfLifeDuration) revert ErrorMinHalfLifeExceedsMax();
        minHalfLifeDuration = _minHalfLifeDuration;
        if (halfLifeDuration < minHalfLifeDuration) {
            halfLifeDuration = minHalfLifeDuration;
        }
    }
    function setMaxHalfLifeDuration(uint256 _maxHalfLifeDuration) external onlyRole(ADMIN_ROLE) {
        if (_maxHalfLifeDuration == 0) revert ErrorMaxHalfLifePositive();
        if (_maxHalfLifeDuration < minHalfLifeDuration) revert ErrorMaxHalfLifeBelowMinimum();
        maxHalfLifeDuration = _maxHalfLifeDuration;
        if (halfLifeDuration > maxHalfLifeDuration) {
            halfLifeDuration = maxHalfLifeDuration;
        }
    }
    function setInactivityResetPeriod(uint256 _inactivityResetPeriod) external onlyRole(ADMIN_ROLE) {
        if (_inactivityResetPeriod == 0) revert ErrorInactivityPeriodPositive();
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
        if (
            interfaceId == type(ERC165Upgradeable).interfaceId ||
            interfaceId == type(AccessControlUpgradeable).interfaceId ||
            interfaceId == type(ERC20Upgradeable).interfaceId ||
            interfaceId == type(ERC20PausableUpgradeable).interfaceId
        ) {
            return true;
        }
        return super.supportsInterface(interfaceId);
    }
}