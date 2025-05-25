// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol"; // Assuming pausable functionality might be needed
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol"; // If needed, though usually not for pure ledger

import "interfaces/IInterbankLiabilityLedger.sol";
import "./CustodianRegistry.sol"; // Assuming CustodianRegistry.sol is in the same directory

/**
 * @title InterbankLiabilityLedger
 * @dev Manages interbank liabilities between custodians.
 * Designed to be a separate, upgradeable contract.
 */
contract InterbankLiabilityLedger is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, IInterbankLiabilityLedger {

    // --- Custom Errors ---
    error errorDebtorNotCustodian();
    error errorCreditorNotCustodian();

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // --- Mappings ---
    mapping(address => mapping(address => uint256)) public interbankLiability; // debtor => creditor => amount

    // Reference to CustodianRegistry for compliance checks
    CustodianRegistry public custodianRegistry;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialAdmin, address _custodianRegistryAddress) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init(); // Initialize ReentrancyGuard

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);

        if (_custodianRegistryAddress == address(0)) revert ErrorZeroAddress();
        custodianRegistry = CustodianRegistry(_custodianRegistryAddress);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    /**
     * @dev Records an interbank liability between a debtor and a creditor.
     * This function is intended to be called by the T3Token contract or an authorized admin.
     * It's marked onlyRole(ADMIN_ROLE) for direct admin control, but in a real system,
     * T3Token itself would likely have a specific role to call this.
     */
    function recordInterbankLiability(address _debtor, address _creditor, uint256 _amount)
        external
        override
        onlyRole(ADMIN_ROLE) // Or a specific role granted to T3Token, if more granular control is desired
        whenNotPaused
        nonReentrant
    {
        if (_debtor == address(0)) revert ErrorZeroAddress();
        if (_creditor == address(0)) revert ErrorZeroAddress();
        if (_debtor == _creditor) revert ErrorDebtorIsCreditor();
        if (_amount == 0) revert ErrorAmountZero();

        // Compliance checks for debtor and creditor from CustodianRegistry
        if (!(custodianRegistry.isKYCValid(_debtor) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), _debtor))) revert ErrorDebtorNotRegistered();
        if (!(custodianRegistry.isKYCValid(_creditor) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), _creditor))) revert ErrorCreditorNotRegistered();
        if (!(custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), _debtor))) revert errorDebtorNotCustodian();
        if (!(custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), _creditor))) revert errorCreditorNotCustodian();

        interbankLiability[_debtor][_creditor] += _amount;
        emit InterbankLiabilityRecorded(_debtor, _creditor, _amount);
    }

    /**
     * @dev Clears a portion of an outstanding interbank liability.
     * This function is intended to be called by the T3Token contract or an authorized admin.
     * It's marked onlyRole(ADMIN_ROLE) for direct admin control, but in a real system,
     * T3Token itself would likely have a specific role to call this.
     */
    function clearInterbankLiability(address _debtor, address _creditor, uint256 _amountToClear)
        external
        override
        onlyRole(ADMIN_ROLE) // Or a specific role granted to T3Token
        whenNotPaused
        nonReentrant
    {
        if (_debtor == address(0)) revert ErrorZeroAddress();
        if (_creditor == address(0)) revert ErrorZeroAddress();
        if (_debtor == _creditor) revert ErrorDebtorIsCreditor();
        if (_amountToClear == 0) revert ErrorAmountZero();

        // Compliance checks for debtor and creditor from CustodianRegistry
        if (!(custodianRegistry.isKYCValid(_debtor) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), _debtor))) revert ErrorDebtorNotRegistered();
        if (!(custodianRegistry.isKYCValid(_creditor) || custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), _creditor))) revert ErrorCreditorNotRegistered();
        if (!(custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), _debtor))) revert errorDebtorNotCustodian();
        if (!(custodianRegistry.hasRole(custodianRegistry.CUSTODIAN_ROLE(), _creditor))) revert errorCreditorNotCustodian();

        uint256 currentLiability = interbankLiability[_debtor][_creditor];
        if (_amountToClear > currentLiability) revert ErrorAmountToClearExceedsLiability();

        interbankLiability[_debtor][_creditor] = currentLiability - _amountToClear;
        emit InterbankLiabilityCleared(_debtor, _creditor, _amountToClear);
    }

    /**
     * @dev Returns the current interbank liability between a debtor and a creditor.
     */
    function getInterbankLiability(address _debtor, address _creditor) public view override returns (uint256) {
        return interbankLiability[_debtor][_creditor];
    }

    /**
     * @dev Admin function to update the CustodianRegistry address.
     * @param _custodianRegistryAddress The new address of the CustodianRegistry.
     */
    function setCustodianRegistryAddress(address _custodianRegistryAddress) external override onlyRole(ADMIN_ROLE) {
        if (_custodianRegistryAddress == address(0)) revert ErrorZeroAddress();
        custodianRegistry = CustodianRegistry(_custodianRegistryAddress);
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
