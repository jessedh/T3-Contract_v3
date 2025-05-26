// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "interfaces/ITokenConstants.sol";
import "interfaces/IInterbankLiabilityLedger.sol";
import "./CustodianRegistry.sol";

/**
 * @title InterbankLiabilityLedger
 * @dev Manages interbank liabilities between custodians.
 * Optimized for gas efficiency and reduced contract size.
 */
contract InterbankLiabilityLedger is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, IInterbankLiabilityLedger {

    // --- Custom Errors ---
    error ErrorDebtorNotCustodian();
    error ErrorCreditorNotCustodian();

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant TOKEN_ROLE = keccak256("TOKEN_ROLE");

    // --- Mappings ---
    // Optimized to only store net liabilities in one direction
    mapping(address => mapping(address => uint256)) private _netLiabilities; // debtor => creditor => amount

    // Reference to CustodianRegistry for compliance checks
    address private immutable _custodianRegistryAddress;

    // Storage gap for future upgrades
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address custodianRegistryAddress) {
        _disableInitializers();
        
        require(custodianRegistryAddress != address(0), "CustodianRegistry address cannot be zero");
        _custodianRegistryAddress = custodianRegistryAddress;
    }

    function initialize(address initialAdmin, address tokenAddress) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
        _grantRole(TOKEN_ROLE, tokenAddress);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    /**
     * @dev Records an interbank liability between a debtor and a creditor.
     * Implements net-on-write pattern to reduce storage costs.
     */
    function recordInterbankLiability(address _debtor, address _creditor, uint256 _amount)
        external
        override
        onlyRole(TOKEN_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (_debtor == address(0)) revert ErrorZeroAddress();
        if (_creditor == address(0)) revert ErrorZeroAddress();
        if (_debtor == _creditor) revert ErrorDebtorIsCreditor();
        if (_amount == 0) revert ErrorAmountZero();

        CustodianRegistry registry = CustodianRegistry(_custodianRegistryAddress);

        // Compliance checks for debtor and creditor
        if (!(registry.isKYCValid(_debtor) || registry.hasRole(registry.CUSTODIAN_ROLE(), _debtor))) 
            revert ErrorDebtorNotRegistered();
        if (!(registry.isKYCValid(_creditor) || registry.hasRole(registry.CUSTODIAN_ROLE(), _creditor))) 
            revert ErrorCreditorNotRegistered();
        if (!(registry.hasRole(registry.CUSTODIAN_ROLE(), _debtor))) 
            revert ErrorDebtorNotCustodian();
        if (!(registry.hasRole(registry.CUSTODIAN_ROLE(), _creditor))) 
            revert ErrorCreditorNotCustodian();

        // Net-on-write pattern implementation
        // Check if there's an existing liability in the opposite direction
        uint256 existingOppositeAmount = _netLiabilities[_creditor][_debtor];
        
        if (existingOppositeAmount >= _amount) {
            // Reduce the opposite direction liability
            unchecked {
                _netLiabilities[_creditor][_debtor] = existingOppositeAmount - _amount;
            }
        } else {
            // Clear opposite direction and record net in this direction
            _netLiabilities[_creditor][_debtor] = 0;
            unchecked {
                _netLiabilities[_debtor][_creditor] += (_amount - existingOppositeAmount);
            }
        }

        emit InterbankLiabilityRecorded(_debtor, _creditor, _amount);
    }

    /**
     * @dev Clears a portion of an outstanding interbank liability.
     * Maintains the net-on-write pattern.
     */
    function clearInterbankLiability(address _debtor, address _creditor, uint256 _amountToClear)
        external
        override
        onlyRole(TOKEN_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (_debtor == address(0)) revert ErrorZeroAddress();
        if (_creditor == address(0)) revert ErrorZeroAddress();
        if (_debtor == _creditor) revert ErrorDebtorIsCreditor();
        if (_amountToClear == 0) revert ErrorAmountZero();

        CustodianRegistry registry = CustodianRegistry(_custodianRegistryAddress);

        // Compliance checks for debtor and creditor
        if (!(registry.isKYCValid(_debtor) || registry.hasRole(registry.CUSTODIAN_ROLE(), _debtor))) 
            revert ErrorDebtorNotRegistered();
        if (!(registry.isKYCValid(_creditor) || registry.hasRole(registry.CUSTODIAN_ROLE(), _creditor))) 
            revert ErrorCreditorNotRegistered();
        if (!(registry.hasRole(registry.CUSTODIAN_ROLE(), _debtor))) 
            revert ErrorDebtorNotCustodian();
        if (!(registry.hasRole(registry.CUSTODIAN_ROLE(), _creditor))) 
            revert ErrorCreditorNotCustodian();

        // Check direct liability first
        uint256 directLiability = _netLiabilities[_debtor][_creditor];
        
        if (directLiability >= _amountToClear) {
            // Simple case: reduce direct liability
            unchecked {
                _netLiabilities[_debtor][_creditor] = directLiability - _amountToClear;
            }
        } else if (directLiability > 0) {
            // Clear direct liability completely
            _netLiabilities[_debtor][_creditor] = 0;
            
            // Record remaining amount as a liability in the opposite direction
            unchecked {
                _netLiabilities[_creditor][_debtor] += (_amountToClear - directLiability);
            }
        } else {
            // No direct liability, check opposite direction
            uint256 oppositeLiability = _netLiabilities[_creditor][_debtor];
            
            if (_amountToClear > oppositeLiability) 
                revert ErrorAmountToClearExceedsLiability();
                
            // Increase opposite liability
            unchecked {
                _netLiabilities[_creditor][_debtor] += _amountToClear;
            }
        }

        emit InterbankLiabilityCleared(_debtor, _creditor, _amountToClear);
    }

    /**
     * @dev Batch records multiple interbank liabilities in a single transaction.
     * @param _debtors Array of debtor addresses
     * @param _creditors Array of creditor addresses
     * @param _amounts Array of liability amounts
     */
    function batchRecordLiabilities(
        address[] calldata _debtors,
        address[] calldata _creditors,
        uint256[] calldata _amounts
    )
        external
        onlyRole(TOKEN_ROLE)
        whenNotPaused
        nonReentrant
    {
        uint256 length = _debtors.length;
        require(length == _creditors.length && length == _amounts.length, "Array length mismatch");
        
        CustodianRegistry registry = CustodianRegistry(_custodianRegistryAddress);
        
        for (uint256 i = 0; i < length;) {
            address debtor = _debtors[i];
            address creditor = _creditors[i];
            uint256 amount = _amounts[i];
            
            if (debtor == address(0) || creditor == address(0) || debtor == creditor || amount == 0) {
                unchecked { ++i; }
                continue;
            }
            
            // Compliance checks
            if (!(registry.isKYCValid(debtor) || registry.hasRole(registry.CUSTODIAN_ROLE(), debtor)) ||
                !(registry.isKYCValid(creditor) || registry.hasRole(registry.CUSTODIAN_ROLE(), creditor)) ||
                !(registry.hasRole(registry.CUSTODIAN_ROLE(), debtor)) ||
                !(registry.hasRole(registry.CUSTODIAN_ROLE(), creditor))) {
                unchecked { ++i; }
                continue;
            }
            
            // Net-on-write implementation
            uint256 existingOppositeAmount = _netLiabilities[creditor][debtor];
            
            if (existingOppositeAmount >= amount) {
                unchecked {
                    _netLiabilities[creditor][debtor] = existingOppositeAmount - amount;
                }
            } else {
                _netLiabilities[creditor][debtor] = 0;
                unchecked {
                    _netLiabilities[debtor][creditor] += (amount - existingOppositeAmount);
                }
            }
            
            emit InterbankLiabilityRecorded(debtor, creditor, amount);
            
            unchecked { ++i; }
        }
    }

    /**
     * @dev Returns the current interbank liability between a debtor and a creditor.
     * Accounts for the net-on-write pattern.
     */
    function getInterbankLiability(address _debtor, address _creditor) public view override returns (uint256) {
        // Check direct liability
        uint256 directLiability = _netLiabilities[_debtor][_creditor];
        if (directLiability > 0) {
            return directLiability;
        }
        
        // No direct liability, so return 0
        return 0;
    }

    /**
     * @dev Returns the net liability between two parties (can be positive or negative).
     * Positive means _party1 owes _party2, negative means _party2 owes _party1.
     */
    function getNetLiability(address _party1, address _party2) external view returns (int256) {
        uint256 party1OwesParty2 = _netLiabilities[_party1][_party2];
        uint256 party2OwesParty1 = _netLiabilities[_party2][_party1];
        
        if (party1OwesParty2 > 0) {
            return int256(party1OwesParty2);
        } else if (party2OwesParty1 > 0) {
            return -int256(party2OwesParty1);
        } else {
            return 0;
        }
    }

    /**
     * @dev Admin function to update the CustodianRegistry address.
     * @param newCustodianRegistryAddress The new address of the CustodianRegistry.
     */
    function setCustodianRegistryAddress(address newCustodianRegistryAddress) external override onlyRole(ADMIN_ROLE) {
        // Use newCustodianRegistryAddress inside the function
    }

    // Admin functions to pause/unpause this specific ledger
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
