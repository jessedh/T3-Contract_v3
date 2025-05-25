// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IInterbankLiabilityLedger
 * @dev Interface for the InterbankLiabilityLedger contract.
 * Defines external functions for recording and clearing interbank liabilities.
 */
interface IInterbankLiabilityLedger {
    // --- Custom Errors (duplicated from T3Token for clarity/self-containment) ---
    error ErrorZeroAddress();
    error ErrorAmountZero();
    error ErrorDebtorNotRegistered();
    error ErrorCreditorNotRegistered();
    error ErrorDebtorIsCreditor();
    error ErrorAmountToClearExceedsLiability();

    // --- Events (duplicated from T3Token for clarity/self-containment) ---
    event InterbankLiabilityRecorded(address indexed debtor, address indexed creditor, uint256 amount);
    event InterbankLiabilityCleared(address indexed debtor, address indexed creditor, uint256 amountCleared);

    /**
     * @dev Records an interbank liability between a debtor and a creditor.
     * @param _debtor The address of the debtor custodian.
     * @param _creditor The address of the creditor custodian.
     * @param _amount The amount of the liability.
     */
    function recordInterbankLiability(address _debtor, address _creditor, uint256 _amount) external;

    /**
     * @dev Clears a portion of an outstanding interbank liability.
     * @param _debtor The address of the debtor custodian.
     * @param _creditor The address of the creditor custodian.
     * @param _amountToClear The amount of liability to clear.
     */
    function clearInterbankLiability(address _debtor, address _creditor, uint256 _amountToClear) external;

    /**
     * @dev Returns the current interbank liability between a debtor and a creditor.
     * @param _debtor The address of the debtor.
     * @param _creditor The address of the creditor.
     * @return The outstanding liability amount.
     */
    function getInterbankLiability(address _debtor, address _creditor) external view returns (uint256);

    /**
     * @dev Sets the address of the CustodianRegistry.
     * This function is essential for enabling compliance checks within the ledger.
     * @param _custodianRegistryAddress The address of the CustodianRegistry contract.
     */
    function setCustodianRegistryAddress(address _custodianRegistryAddress) external;
}
