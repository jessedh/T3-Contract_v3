// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Using Upgradeable OpenZeppelin Contracts
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// Import Custom Modules
import "./TokenConstants.sol";
import "./CustodianRegistry.sol";
import "./FeeCalculationLibrary.sol";
import "interfaces/ILockedTransferManager.sol";
import "interfaces/IInterbankLiabilityLedger.sol";
import "./ModuleAddresses.sol";


/**
 * @title T3Token (T3USD) - Optimized Upgradeable Stablecoin
 * @dev Refactored to reduce contract size and improve gas efficiency.
 * Integrates with external modules for compliance, fee calculation, transfers, and liability tracking.
 */
contract T3Token is Initializable, ERC20PausableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using Math for uint256;

    // --- Custom Errors ---
    error ErrorZeroAddress();
    error ErrorAmountZero();
    error ErrorInsufficientPrefundedBalance();
    error ErrorSenderNotRegistered();
    error ErrorRecipientNotRegistered();
    error ErrorSpenderNotRegistered();
    error ErrorAccountNotRegistered();
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

    // --- HalfLife Constants ---
    uint256 public halfLifeDuration;
    uint256 public minHalfLifeDuration;
    uint256 public maxHalfLifeDuration;
    uint256 public inactivityResetPeriod;

    // --- Addresses ---
    address public treasuryAddress;
    
    // Module references - stored in immutable proxy state contract
    address private immutable _moduleAddressesContract;

    // --- Data Structures ---
    // Original TransferMetadata struct (for sender's HalfLife tracking)
    struct TransferMetadata {
        uint64 commitWindowEnd;      // Reduced from uint256
        uint64 halfLifeDuration;     // Reduced from uint256
        address originator;
        uint32 transferCount;        // Reduced from uint256
        bytes32 reversalHash;
        uint96 totalFeeAssessed;     // Reduced from uint256
        bool isReversed;
    }
    
    // Optimized HalfLifeTransfer struct (for recipient's pending funds)
    struct HalfLifeTransfer {
        address sender;
        uint128 amount;              // Reduced from uint256
        uint64 expiryTimestamp;      // Reduced from uint256
        bool reversed;
        bool finalized;
    }

    // Optimized RollingAverage struct
    struct RollingAverage {
        uint256 totalAmount;         // Reduced from uint256
        uint256 count;                // Reduced from uint256
        uint256 lastUpdated;          // Reduced from uint256
    }
    
    // Optimized WalletRiskProfile struct
    struct WalletRiskProfile {
        uint32 reversalCount;        // Reduced from uint256
        uint64 lastReversal;         // Reduced from uint256
        uint64 creationTime;         // Reduced from uint256
        uint32 abnormalTxCount;      // Reduced from uint256
    }
    
    // Optimized IncentiveCredits struct
    struct IncentiveCredits {
        uint128 amount;              // Reduced from uint256
        uint64 lastUpdated;          // Reduced from uint256
    }
    
    struct FeeDetails {
        uint256 requestedAmount;
        uint256 baseFeeAmount;
        uint256 senderRiskScore;
        uint256 recipientRiskScore;
        uint256 applicableRiskScore;
        uint256 amountRiskScaler;
        uint256 scaledRiskImpactBps;
        uint224 finalRiskFactorBps;
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
    mapping(address => HalfLifeTransfer) public pendingHalfLifeTransfers;
    mapping(address => RollingAverage) public rollingAverages;
    mapping(address => mapping(address => uint32)) public transactionCountBetween; // Reduced from uint256
    mapping(address => WalletRiskProfile) public walletRiskProfiles;
    mapping(address => IncentiveCredits) public incentiveCredits;
    mapping(address => uint256) public mintedByMinter;
    mapping(address => uint256) public prefundedFeeBalances;

    // --- Events ---
    // Optimized with indexed parameters for efficient filtering
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
    event TokensMinted(address indexed minter, address indexed recipient, uint256 amount);
    event FeePrefunded(address indexed user, uint256 amount);
    event PrefundedFeeWithdrawn(address indexed user, uint256 amount);
    event PrefundedFeeUsed(address indexed user, uint256 amountUsed);
    event IncentiveCreditUsed(address indexed user, uint256 amountUsed);
    event RecipientTransferPending(address indexed sender, address indexed recipient, uint256 amount, uint256 expiryTimestamp);
    event RecipientTransferReversed(address indexed sender, address indexed recipient, uint256 amount);
    event RecipientTransferFinalized(address indexed sender, address indexed recipient, uint256 amount);
    event BatchTransferProcessed(address indexed sender, uint256 count, uint256 totalAmount, uint256 totalFees);

    // Storage gap for future upgrades
    uint256[50] private __gap;


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address moduleAddressesContract) {
        _disableInitializers();
        require(moduleAddressesContract != address(0), "Module addresses contract cannot be zero");
        _moduleAddressesContract = moduleAddressesContract;
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

        if (_treasuryAddress == address(0)) revert ErrorTreasuryAddressZero();
        treasuryAddress = _treasuryAddress;

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);

        if (initialMintAmount > 0) {
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
            walletRiskProfiles[initialAdmin].creationTime = uint64(block.timestamp);
        }
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(ADMIN_ROLE)
    {
        // Intentionally empty
    }

    // --- Module Access Functions ---
    
    function getCustodianRegistry() public view returns (CustodianRegistry) {
        return CustodianRegistry(ModuleAddresses(_moduleAddressesContract).custodianRegistry());
    }
    
    function getLockedTransferManager() public view returns (ILockedTransferManager) {
        return ILockedTransferManager(ModuleAddresses(_moduleAddressesContract).lockedTransferManager());
    }
    
    function getInterbankLiabilityLedger() public view returns (IInterbankLiabilityLedger) {
        return IInterbankLiabilityLedger(ModuleAddresses(_moduleAddressesContract).interbankLiabilityLedger());
    }

    // --- Fee Pre-funding Functions ---

    function prefundFees(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ErrorAmountZero();
        address sender = _msgSender();
        
        // Compliance check for sender
        CustodianRegistry registry = getCustodianRegistry();
        if (!(registry.isKYCValid(sender) || registry.hasRole(registry.CUSTODIAN_ROLE(), sender))) 
            revert ErrorSenderNotRegistered();

        super._transfer(sender, treasuryAddress, amount);
        
        unchecked {
            prefundedFeeBalances[sender] += amount;
        }

        emit FeePrefunded(sender, amount);
    }

    function withdrawPrefundedFees(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ErrorAmountZero();
        address sender = _msgSender();
        if (prefundedFeeBalances[sender] < amount) revert ErrorInsufficientPrefundedBalance();
        
        // Compliance check for sender
        CustodianRegistry registry = getCustodianRegistry();
        if (!(registry.isKYCValid(sender) || registry.hasRole(registry.CUSTODIAN_ROLE(), sender))) 
            revert ErrorSenderNotRegistered();

        unchecked {
            prefundedFeeBalances[sender] -= amount;
        }
        super._transfer(treasuryAddress, sender, amount);

        emit PrefundedFeeWithdrawn(sender, amount);
    }

    // --- Transfer Logic ---

    function transfer(address recipient, uint256 amountIntendedForRecipient) public virtual override whenNotPaused returns (bool) {
        address sender = _msgSender();
        
        // Compliance check for sender and recipient
        CustodianRegistry registry = getCustodianRegistry();
        if (!(registry.isKYCValid(sender) || registry.hasRole(registry.CUSTODIAN_ROLE(), sender))) 
            revert ErrorSenderNotRegistered();
        if (!(registry.isKYCValid(recipient) || registry.hasRole(registry.CUSTODIAN_ROLE(), recipient))) 
            revert ErrorRecipientNotRegistered();

        _ensureProfileExists(sender);
        _ensureProfileExists(recipient);
        _transferWithT3Logic(sender, recipient, amountIntendedForRecipient);
        return true;
    }

    function transferFrom(address from, address to, uint256 amountIntendedForRecipient) public virtual override whenNotPaused returns (bool) {
        address spender = _msgSender();
        
        // Compliance check for from, to, and spender
        CustodianRegistry registry = getCustodianRegistry();
        if (!(registry.isKYCValid(from) || registry.hasRole(registry.CUSTODIAN_ROLE(), from))) 
            revert ErrorSenderNotRegistered();
        if (!(registry.isKYCValid(to) || registry.hasRole(registry.CUSTODIAN_ROLE(), to))) 
            revert ErrorRecipientNotRegistered();
        if (!(registry.isKYCValid(spender) || registry.hasRole(registry.CUSTODIAN_ROLE(), spender))) 
            revert ErrorSpenderNotRegistered();

        _spendAllowance(from, spender, amountIntendedForRecipient);
        _ensureProfileExists(from);
        _ensureProfileExists(to);
        _transferWithT3Logic(from, to, amountIntendedForRecipient);
        return true;
    }
    
    /**
     * @dev Batch transfer function to reduce gas costs for multiple transfers
     * @param recipients Array of recipient addresses
     * @param amounts Array of amounts to transfer
     * @return Array of booleans indicating success of each transfer
     */
    function batchTransfer(
        address[] calldata recipients, 
        uint256[] calldata amounts
    ) 
        external 
        whenNotPaused 
        nonReentrant 
        returns (bool[] memory) 
    {
        uint256 length = recipients.length;
        require(length == amounts.length, "Array length mismatch");
        require(length > 0, "Empty arrays");
        
        address sender = _msgSender();
        bool[] memory results = new bool[](length);
        uint256 totalAmount = 0;
        uint256 totalFees = 0;
        
        // Compliance check for sender
        CustodianRegistry registry = getCustodianRegistry();
        if (!(registry.isKYCValid(sender) || registry.hasRole(registry.CUSTODIAN_ROLE(), sender))) 
            revert ErrorSenderNotRegistered();
        
        _ensureProfileExists(sender);
        
        for (uint256 i = 0; i < length;) {
            address recipient = recipients[i];
            uint256 amount = amounts[i];
            
            // Skip invalid transfers
            if (recipient == address(0) || amount == 0) {
                results[i] = false;
                unchecked { ++i; }
                continue;
            }
            
            // Compliance check for recipient
            if (!(registry.isKYCValid(recipient) || registry.hasRole(registry.CUSTODIAN_ROLE(), recipient))) {
                results[i] = false;
                unchecked { ++i; }
                continue;
            }
            
            _ensureProfileExists(recipient);
            
            // Check HalfLife constraints
            if (transferData[sender].commitWindowEnd > block.timestamp &&
                transferData[sender].originator != recipient &&
                sender != transferData[recipient].originator) {
                results[i] = false;
                unchecked { ++i; }
                continue;
            }
            
            try this.transfer(recipient, amount) returns (bool success) {
                results[i] = success;
                if (success) {
                    unchecked {
                        totalAmount += amount;
                        totalFees += transferData[recipient].totalFeeAssessed;
                    }
                }
            } catch {
                results[i] = false;
            }
            
            unchecked { ++i; }
        }
        
        emit BatchTransferProcessed(sender, length, totalAmount, totalFees);
        return results;
    }

    function _calculateTotalFeeAssessed(
        address sender,
        address recipient,
        uint256 amountIntendedForRecipient
    ) internal view returns (uint256) {
        // Use library function for base fee calculation
        uint256 baseFeeAmount = FeeCalculationLibrary.calculateBaseFeeAmount(amountIntendedForRecipient);
        
        // Apply risk adjustments
        uint256 feeAfterRisk = applyRiskAdjustments(baseFeeAmount, sender, recipient, amountIntendedForRecipient);
        
        // Apply bounds
        uint256 maxFeeBound = Math.mulDiv(amountIntendedForRecipient, TokenConstants.MAX_FEE_PERCENT_BPS, TokenConstants.BASIS_POINTS);
        uint256 minFeeBound = TokenConstants.MIN_FEE_WEI;
        
        uint256 finalFee = feeAfterRisk;
        
        // Apply max fee bound
        if (finalFee > maxFeeBound) {
            finalFee = maxFeeBound;
        }
        
        // Apply min fee bound if applicable
        if (finalFee > 0 && finalFee < minFeeBound && amountIntendedForRecipient >= minFeeBound) {
            if (minFeeBound <= maxFeeBound && minFeeBound <= amountIntendedForRecipient) {
                finalFee = minFeeBound;
            }
        }
        
        return finalFee;
    }

    function _handleFeePaymentAndTransfers(
        address sender,
        address recipient,
        uint256 amountIntendedForRecipient,
        uint256 totalFeeAssessedForTx
    ) internal returns (
        uint256 feePaidFromPrefund,
        uint256 feePaidFromCredits,
        uint256 feePaidFromBalanceNow
    ) {
        if (totalFeeAssessedForTx == 0) {
            super._transfer(sender, recipient, amountIntendedForRecipient);
            return (0, 0, 0);
        }

        // Apply credits first
        uint256 feeRemainingAfterCredits;
        (feeRemainingAfterCredits, feePaidFromCredits) = applyCredits(sender, totalFeeAssessedForTx);
        
        if (feePaidFromCredits > 0) {
            emit IncentiveCreditUsed(sender, feePaidFromCredits);
        }

        // If credits covered everything, just transfer the intended amount
        if (feeRemainingAfterCredits == 0) {
            super._transfer(sender, recipient, amountIntendedForRecipient);
            return (0, feePaidFromCredits, 0);
        }

        // Apply prefunded fees next
        uint256 prefundedBalance = prefundedFeeBalances[sender];
        feePaidFromPrefund = prefundedBalance >= feeRemainingAfterCredits ? feeRemainingAfterCredits : prefundedBalance;
        
        if (feePaidFromPrefund > 0) {
            unchecked {
                prefundedFeeBalances[sender] -= feePaidFromPrefund;
            }
            emit PrefundedFeeUsed(sender, feePaidFromPrefund);
        }

        // Calculate remaining fee to be paid from balance
        feePaidFromBalanceNow = feeRemainingAfterCredits - feePaidFromPrefund;

        // Transfer logic
        if (feePaidFromBalanceNow > 0) {
            // Transfer fee from balance to treasury
            super._transfer(sender, treasuryAddress, feePaidFromBalanceNow);
        }
        
        // Transfer intended amount to recipient
        super._transfer(sender, recipient, amountIntendedForRecipient);

        return (feePaidFromPrefund, feePaidFromCredits, feePaidFromBalanceNow);
    }

    function _updatePostTransferMetadata(
        address sender,
        address recipient,
        uint256 amountIntendedForRecipient,
        uint256 finalTotalFeeAssessed
    ) internal {
        unchecked {
            transactionCountBetween[sender][recipient]++;
        }
        uint256 adaptiveHalfLife = calculateAdaptiveHalfLife(sender, recipient, amountIntendedForRecipient);

        // Original sender-side HalfLife tracking
        transferData[recipient] = TransferMetadata({
            commitWindowEnd: uint64(block.timestamp + adaptiveHalfLife),
            halfLifeDuration: uint64(adaptiveHalfLife),
            originator: sender,
            transferCount: uint32(transferData[recipient].transferCount + 1),
            reversalHash: keccak256(abi.encodePacked(sender, recipient, amountIntendedForRecipient)),
            totalFeeAssessed: uint96(finalTotalFeeAssessed),
            isReversed: false
        });
        updateRollingAverage(recipient, amountIntendedForRecipient);

        // Recipient-side HalfLife tracking
        _finalizeRecipientHalfLifeTransfer(recipient);

        pendingHalfLifeTransfers[recipient] = HalfLifeTransfer({
            sender: sender,
            amount: uint128(amountIntendedForRecipient),
            expiryTimestamp: uint64(block.timestamp + adaptiveHalfLife),
            reversed: false,
            finalized: false
        });
        emit RecipientTransferPending(sender, recipient, amountIntendedForRecipient, block.timestamp + adaptiveHalfLife);
    }

    function _transferWithT3Logic(address sender, address recipient, uint256 amountIntendedForRecipient) internal {
        if (recipient == address(0)) revert ErrorZeroAddress();
        if (amountIntendedForRecipient == 0) revert ErrorAmountZero();

        // HalfLife check
        if (transferData[sender].commitWindowEnd > block.timestamp &&
            transferData[sender].originator != recipient &&
            sender != transferData[recipient].originator
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

        // Interbank Liability Logic - delegated to external contract
        CustodianRegistry registry = getCustodianRegistry();
        address senderCustodian = registry.getCustodian(sender);
        address recipientCustodian = registry.getCustodian(recipient);

        if (senderCustodian != address(0) && recipientCustodian != address(0) && senderCustodian != recipientCustodian) {
            // Call the external InterbankLiabilityLedger contract
            getInterbankLiabilityLedger().recordInterbankLiability(senderCustodian, recipientCustodian, amountIntendedForRecipient);
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
        
        unchecked {
            uint256 senderCreditShare = totalFeeAssessedForCreditAllocation / 4;
            uint256 recipientCreditShare = totalFeeAssessedForCreditAllocation / 4;
    
            if (senderCreditShare > 0) {
                incentiveCredits[sender].amount += uint128(senderCreditShare);
                incentiveCredits[sender].lastUpdated = uint64(block.timestamp);
            }
            if (recipientCreditShare > 0) {
                incentiveCredits[recipient].amount += uint128(recipientCreditShare);
                incentiveCredits[recipient].lastUpdated = uint64(block.timestamp);
            }
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
        
        uint256 riskDeviation = applicableRiskScore > TokenConstants.BASIS_POINTS ? 
            applicableRiskScore - TokenConstants.BASIS_POINTS : 0;
            
        if (riskDeviation == 0) {
            return baseFeeAmount;
        }
        
        // Using library function
        uint256 amountScalerBps = FeeCalculationLibrary.calculateAmountRiskScaler(amount, decimals());
        uint256 scaledRiskImpactBps = Math.mulDiv(riskDeviation, amountScalerBps, TokenConstants.BASIS_POINTS);
        uint256 finalRiskFactorBps = TokenConstants.BASIS_POINTS + scaledRiskImpactBps;
        
        feeAfterRisk = Math.mulDiv(baseFeeAmount, finalRiskFactorBps, TokenConstants.BASIS_POINTS);
        return feeAfterRisk;
    }

    function calculateRiskFactor(address wallet) public view returns (uint256) {
    _ensureProfileExists(wallet);
    WalletRiskProfile storage profile = walletRiskProfiles[wallet];
    return T3TokenLogicLibrary.calculateRiskFactor(
        profile.creationTime,
        profile.lastReversal,
        profile.reversalCount,
        profile.abnormalTxCount,
        TokenConstants.BASIS_POINTS
    );
}
    function applyCredits(address wallet, uint256 feeToCover) internal returns (uint256 remainingFeeAfterCredits, uint256 creditsActuallyUsed) {
        IncentiveCredits storage credits = incentiveCredits[wallet];
        if (credits.amount == 0 || feeToCover == 0) {
            return (feeToCover, 0);
        }
        
        if (credits.amount >= feeToCover) {
            creditsActuallyUsed = feeToCover;
            unchecked {
                credits.amount -= uint128(feeToCover);
            }
            credits.lastUpdated = uint64(block.timestamp);
            remainingFeeAfterCredits = 0;
            return (remainingFeeAfterCredits, creditsActuallyUsed);
        } else {
            creditsActuallyUsed = credits.amount;
            remainingFeeAfterCredits = feeToCover - credits.amount;
            credits.amount = 0;
            credits.lastUpdated = uint64(block.timestamp);
            return (remainingFeeAfterCredits, creditsActuallyUsed);
        }
    }

    function calculateAdaptiveHalfLife(address sender, address recipient, uint256 amount) internal view returns (uint256) {
    //get the rolling average for the sender
    RollingAverage storage avg = rollingAverages[sender];
    return T3TokenLogicLibrary.calculateAdaptiveHalfLife
    (
        amount,
        halfLifeDuration,
        transactionCountBetween[sender][recipient],
        avg.count,
        avg.totalAmount,
        minHalfLifeDuration,
        maxHalfLifeDuration
    );

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
        
        unchecked {
            profile.reversalCount++;
        }
        profile.lastReversal = uint64(block.timestamp);
    }

    function _ensureProfileExists(address wallet) internal view {
        // No-op for view functions, as it's a read-only check.
    }

    function _ensureProfileExistsForWrite(address wallet) internal {
        if (wallet != address(0) && walletRiskProfiles[wallet].creationTime == 0) {
            walletRiskProfiles[wallet].creationTime = uint64(block.timestamp);
        }
    }

    // --- Recipient HalfLife Functions ---

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
        CustodianRegistry registry = getCustodianRegistry();
        if (!(registry.isKYCValid(_msgSender()) || registry.hasRole(registry.CUSTODIAN_ROLE(), _msgSender()))) 
            revert ErrorRecipientNotRegistered();
        if (!(registry.isKYCValid(pending.sender) || registry.hasRole(registry.CUSTODIAN_ROLE(), pending.sender))) 
            revert ErrorSenderNotRegistered();

        // Transfer tokens back to the original sender
        super._transfer(_msgSender(), pending.sender, pending.amount);

        pending.reversed = true; // Mark as reversed

        // Interbank Liability Logic for Reversal
        address senderCustodian = registry.getCustodian(pending.sender);
        address recipientCustodian = registry.getCustodian(_msgSender());

        if (senderCustodian != address(0) && recipientCustodian != address(0) && senderCustodian != recipientCustodian) {
            // Call the external InterbankLiabilityLedger contract to clear the liability
            getInterbankLiabilityLedger().clearInterbankLiability(senderCustodian, recipientCustodian, pending.amount);
        }

        emit RecipientTransferReversed(pending.sender, _msgSender(), pending.amount);
    }

    /**
     * @dev Allows anyone to finalize an expired HalfLife transfer for a given recipient.
     * Also called internally by _updatePostTransferMetadata if a new transfer comes in.
     */
    function finalizeRecipientTransfer(address _recipient) public nonReentrant whenNotPaused {
        HalfLifeTransfer storage pending = pendingHalfLifeTransfers[_recipient];
        if (pending.sender == address(0)) revert ErrorNoActiveTransfer();
        if (pending.finalized) revert ErrorTransferFinalized();
        if (pending.reversed) revert ErrorTransferReversed();
        if (block.timestamp < pending.expiryTimestamp) revert ErrorHalfLifeNotExpired();

        // Compliance check for recipient and sender
        CustodianRegistry registry = getCustodianRegistry();
        if (!(registry.isKYCValid(_recipient) || registry.hasRole(registry.CUSTODIAN_ROLE(), _recipient))) 
            revert ErrorRecipientNotRegistered();
        if (!(registry.isKYCValid(pending.sender) || registry.hasRole(registry.CUSTODIAN_ROLE(), pending.sender))) 
            revert ErrorSenderNotRegistered();

        pending.finalized = true; // Mark as finalized

        // Award incentive credits from original fee
        uint256 feeAssessedForOriginalTx = transferData[_recipient].totalFeeAssessed;
        if (feeAssessedForOriginalTx > 0) {
            unchecked {
                uint256 totalRefundAmount = feeAssessedForOriginalTx / 8; // 12.5% of total fee
                if (totalRefundAmount > 0) {
                    uint256 refundPerParty = totalRefundAmount / 2;
                    if (refundPerParty > 0) {
                        incentiveCredits[pending.sender].amount += uint128(refundPerParty);
                        incentiveCredits[pending.sender].lastUpdated = uint64(block.timestamp);
                        emit LoyaltyRefundProcessed(pending.sender, refundPerParty);
    
                        incentiveCredits[_recipient].amount += uint128(refundPerParty);
                        incentiveCredits[_recipient].lastUpdated = uint64(block.timestamp);
                        emit LoyaltyRefundProcessed(_recipient, refundPerParty);
                    }
                }
            }
        }

        delete pendingHalfLifeTransfers[_recipient]; // Clear the pending entry
        emit RecipientTransferFinalized(pending.sender, _recipient, pending.amount);
    }

    /**
     * @dev Internal function to finalize a recipient's HalfLife transfer if expired.
     */
    function _finalizeRecipientHalfLifeTransfer(address _recipient) internal {
        HalfLifeTransfer storage pending = pendingHalfLifeTransfers[_recipient];
        if (pending.sender != address(0) && !pending.finalized && !pending.reversed && block.timestamp >= pending.expiryTimestamp) {
            pending.finalized = true;
            
            // Award incentive credits
            uint256 feeAssessedForOriginalTx = transferData[_recipient].totalFeeAssessed;
            if (feeAssessedForOriginalTx > 0) {
                unchecked {
                    uint256 totalRefundAmount = feeAssessedForOriginalTx / 8; // 12.5% of total fee
                    if (totalRefundAmount > 0) {
                        uint256 refundPerParty = totalRefundAmount / 2;
                        if (refundPerParty > 0) {
                            incentiveCredits[pending.sender].amount += uint128(refundPerParty);
                            incentiveCredits[pending.sender].lastUpdated = uint64(block.timestamp);
                            emit LoyaltyRefundProcessed(pending.sender, refundPerParty);
        
                            incentiveCredits[_recipient].amount += uint128(refundPerParty);
                            incentiveCredits[_recipient].lastUpdated = uint64(block.timestamp);
                            emit LoyaltyRefundProcessed(_recipient, refundPerParty);
                        }
                    }
                }
            }
            
            delete pendingHalfLifeTransfers[_recipient];
            emit RecipientTransferFinalized(pending.sender, _recipient, pending.amount);
        }
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

        // Compliance check for sender and recipient
        CustodianRegistry registry = getCustodianRegistry();
        if (!(registry.isKYCValid(sender) || registry.hasRole(registry.CUSTODIAN_ROLE(), sender))) 
            revert ErrorSenderNotRegistered();
        if (!(registry.isKYCValid(recipient) || registry.hasRole(registry.CUSTODIAN_ROLE(), recipient))) 
            revert ErrorRecipientNotRegistered();

        details.requestedAmount = amountIntendedForRecipient;

        // Using library function
        uint256 baseFee = FeeCalculationLibrary.calculateBaseFeeAmount(amountIntendedForRecipient);
        uint256 feeAfterRiskCalc = applyRiskAdjustments(baseFee, sender, recipient, amountIntendedForRecipient);

        details.totalFeeAssessed = feeAfterRiskCalc;
        details.maxFeeBound = Math.mulDiv(amountIntendedForRecipient, TokenConstants.MAX_FEE_PERCENT_BPS, TokenConstants.BASIS_POINTS);
        
        if (details.totalFeeAssessed > details.maxFeeBound) {
            details.totalFeeAssessed = details.maxFeeBound;
            details.maxFeeApplied = true;
        } else {
            details.maxFeeApplied = false;
        }

        details.minFeeBound = TokenConstants.MIN_FEE_WEI;
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

        if (details.availableCredits == 0 || details.totalFeeAssessed == 0) {
            details.creditsToApply = 0;
            details.feeAfterCredits = details.totalFeeAssessed;
        } else if (details.availableCredits >= details.totalFeeAssessed) {
            details.creditsToApply = details.totalFeeAssessed;
            details.feeAfterCredits = 0;
        } else {
            details.creditsToApply = details.availableCredits;
            details.feeAfterCredits = details.totalFeeAssessed - details.availableCredits;
        }

        details.netAmountToSendToRecipient = amountIntendedForRecipient;

        return details;
    }

    // View function for recipient-side HalfLife
    function getPendingRecipientTransfer(address _recipient) public view returns (address sender, uint256 amount, uint256 expiryTimestamp, bool reversed, bool finalized) {
        HalfLifeTransfer storage pending = pendingHalfLifeTransfers[_recipient];
        return (pending.sender, pending.amount, pending.expiryTimestamp, pending.reversed, pending.finalized);
    }

    // --- Minting and Burning Functions ---
    
    function mint(address recipient, uint256 amount) external whenNotPaused onlyRole(MINTER_ROLE) {
        if (recipient == address(0)) revert ErrorZeroAddress();
        if (amount == 0) revert ErrorAmountZero();
        address minterAccount = _msgSender();
        
        // Compliance check for recipient
        CustodianRegistry registry = getCustodianRegistry();
        if (!(registry.isKYCValid(recipient) || registry.hasRole(registry.CUSTODIAN_ROLE(), recipient))) 
            revert ErrorRecipientNotRegistered();

        super._mint(recipient, amount);
        
        unchecked {
            mintedByMinter[minterAccount] += amount;
        }
        _ensureProfileExistsForWrite(recipient);
        emit TokensMinted(minterAccount, recipient, amount);
    }
    
    /**
     * @dev Batch mint function to reduce gas costs for multiple mints
     * @param recipients Array of recipient addresses
     * @param amounts Array of amounts to mint
     */
    function batchMint(
        address[] calldata recipients, 
        uint256[] calldata amounts
    ) 
        external 
        whenNotPaused 
        onlyRole(MINTER_ROLE) 
        nonReentrant 
    {
        uint256 length = recipients.length;
        require(length == amounts.length, "Array length mismatch");
        require(length > 0, "Empty arrays");
        
        address minterAccount = _msgSender();
        CustodianRegistry registry = getCustodianRegistry();
        
        for (uint256 i = 0; i < length;) {
            address recipient = recipients[i];
            uint256 amount = amounts[i];
            
            // Skip invalid mints
            if (recipient == address(0) || amount == 0) {
                unchecked { ++i; }
                continue;
            }
            
            // Compliance check for recipient
            if (!(registry.isKYCValid(recipient) || registry.hasRole(registry.CUSTODIAN_ROLE(), recipient))) {
                unchecked { ++i; }
                continue;
            }
            
            super._mint(recipient, amount);
            
            unchecked {
                mintedByMinter[minterAccount] += amount;
                ++i;
            }
            
            _ensureProfileExistsForWrite(recipient);
            emit TokensMinted(minterAccount, recipient, amount);
        }
    }

    function burn(uint256 amount) external whenNotPaused {
        if (amount == 0) revert ErrorAmountZero();
        
        // Compliance check for burner
        CustodianRegistry registry = getCustodianRegistry();
        if (!(registry.isKYCValid(_msgSender()) || registry.hasRole(registry.CUSTODIAN_ROLE(), _msgSender()))) 
            revert ErrorSenderNotRegistered();
            
        super._burn(_msgSender(), amount);
    }

    function burnFrom(address account, uint256 amount) external whenNotPaused {
        if (amount == 0) revert ErrorAmountZero();
        address spender = _msgSender();
        
        // Compliance check for account and spender
        CustodianRegistry registry = getCustodianRegistry();
        if (!(registry.isKYCValid(account) || registry.hasRole(registry.CUSTODIAN_ROLE(), account))) 
            revert ErrorAccountNotRegistered();
        if (!(registry.isKYCValid(spender) || registry.hasRole(registry.CUSTODIAN_ROLE(), spender))) 
            revert ErrorSpenderNotRegistered();
            
        _spendAllowance(account, spender, amount);
        super._burn(account, amount);
    }

    // --- Admin / Role Management Functions ---
    
    function flagAbnormalTransaction(address wallet) external onlyRole(ADMIN_ROLE) {
        _ensureProfileExistsForWrite(wallet);
        unchecked {
            walletRiskProfiles[wallet].abnormalTxCount++;
        }
    }
    
    function setTreasuryAddress(address _treasuryAddress) external onlyRole(ADMIN_ROLE) {
        if (_treasuryAddress == address(0)) revert ErrorTreasuryAddressZero();
        treasuryAddress = _treasuryAddress;
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
