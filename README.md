## Release Notes: T3 Smart Contract System (v3)

This release introduces the T3 Smart Contract System, featuring the T3Token (a stablecoin with advanced fee and risk management capabilities) and the CustodianRegistry (for managing custodied wallets and KYC status). The system is built using upgradeable contracts following the UUPS proxy pattern.

### Key Features & Changes

#### T3Token (`T3Token.sol`)
The T3Token is an ERC20-compliant token with several innovative features designed for robust and flexible digital currency operations:

* **Core Token Functionality**:
    * Standard ERC20 functions: `transfer`, `transferFrom`, `approve`, `balanceOf`, `totalSupply`, `name`, `symbol`, `decimals`.
    * Minting and Burning:
        * `mint`: Allows accounts with the `MINTER_ROLE` to create new tokens.
        * `burn`: Allows token holders to burn their own tokens.
        * `burnFrom`: Allows approved spenders (including those with `BURNER_ROLE`) to burn tokens from other accounts.
    * Pausable: Contract operations can be paused and unpaused by accounts with the `PAUSER_ROLE`.
    * Reentrancy Guard: Protects against reentrancy attacks on critical functions.
* **Advanced Fee Mechanism**:
    * **Pre-funded Fees**: Users can pre-fund their fee balances (`prefundFees`, `withdrawPrefundedFees`, `getPrefundedFeeBalance`) which can then be used to cover transaction fees.
    * **Incentive Credits**: Users can earn incentive credits (`getAvailableCredits`), which can be applied to reduce transaction fees.
    * **Risk-Adjusted Fees**:
        * `calculateRiskFactor`: Determines a risk score for wallets based on factors like wallet age and reversal history.
        * `estimateTransferFeeDetails`: Provides an estimation of fees for a transfer, considering base fees, risk adjustments, and applicable credits.
        * Fees are calculated considering a base fee, an amount-based risk scaler, and wallet risk profiles.
    * **Fee Handling**: Fees are paid from pre-funded balances first, then incentive credits, and finally from the user's token balance. A portion of the collected fees is directed to the `treasuryAddress`, and shares are allocated as incentive credits to the sender and recipient.
* **HalfLife Mechanism**:
    * Transfers to a recipient initiate a "HalfLife" period (`halfLifeDuration`) during which the received tokens are subject to certain restrictions.
    * The duration of the HalfLife can be adaptive (`calculateAdaptiveHalfLife`) based on transaction history and amounts.
    * `checkHalfLifeExpiry`: Allows checking and processing the expiry of a HalfLife period, potentially triggering loyalty refunds (a portion of the initial transaction fee credited back).
    * **Transfer Reversals**:
        * `reverseTransfer`: Allows the originator of a transfer to reverse it within the commit window (HalfLife period) under certain conditions. This action updates wallet risk profiles.
* **Wallet Risk Management**:
    * `flagAbnormalTransaction`: Allows an admin to flag a wallet for abnormal transaction activity, impacting its risk score.
    * Rolling averages of transaction amounts and counts are maintained (`rollingAverages`, `transactionCountBetween`).
    * Wallet profiles track reversal counts, last reversal timestamp, creation time, and abnormal transaction counts (`walletRiskProfiles`).
* **Interbank Liability Management**:
    * `recordInterbankLiability` and `clearInterbankLiability`: Functions for admin to manage off-chain liabilities between entities.
* **Configurable Parameters (Admin-controlled)**:
    * `setTreasuryAddress`
    * `setHalfLifeDuration`, `setMinHalfLifeDuration`, `setMaxHalfLifeDuration`
    * `setInactivityResetPeriod` (for resetting rolling averages)
* **Upgradeable (UUPS)**: The contract is designed to be upgradeable using the UUPS proxy pattern, with `_authorizeUpgrade` controlled by the `ADMIN_ROLE`.
* **Access Control**: Utilizes OpenZeppelin's `AccessControlUpgradeable` for managing roles like `ADMIN_ROLE`, `MINTER_ROLE`, `BURNER_ROLE`, and `PAUSER_ROLE`.

#### CustodianRegistry (`CustodianRegistry.sol`)
The CustodianRegistry manages financial institutions (FIs) acting as custodians for user wallets and their associated KYC (Know Your Customer) status.

* **Role Management**:
    * `ADMIN_ROLE`: Can grant and revoke the `CUSTODIAN_ROLE`.
    * `CUSTODIAN_ROLE`: Allows authorized entities (FIs) to manage custodied wallets.
* **Custodian and Wallet Management**:
    * `grantCustodianRole` / `revokeCustodianRole`: Admin functions to manage which addresses have the `CUSTODIAN_ROLE`.
    * `registerCustodiedWallet`: Allows an FI with `CUSTODIAN_ROLE` to register a user's wallet, linking it to the custodian and recording KYC validation and expiration timestamps.
    * `unregisterCustodiedWallet`: Allows the registered custodian to remove a wallet's registration.
    * `updateKYCStatus`: Allows the registered custodian to update the KYC timestamps for a custodied wallet.
* **KYC Information Retrieval**:
    * `getCustodian`: Returns the custodian address for a given user wallet.
    * `getKYCTimestamps`: Returns the KYC validation and expiration timestamps for a user wallet.
    * `isKYCValid`: Checks if a user's KYC is currently valid based on the stored timestamps and the current block time.
* **Transparency**:
    * `custodianCount`: Returns the total number of registered custodians.
    * `custodianAtIndex`: Allows retrieval of custodian addresses by index.
* **Upgradeable (UUPS)**: The contract is upgradeable, with `_authorizeUpgrade` controlled by the `ADMIN_ROLE`.
* **Access Control**: Implements `AccessControlUpgradeable`.

### Technical Details

* **Solidity Version**: Contracts are written for `^0.8.24`.
* **OpenZeppelin Dependencies**: Utilizes various upgradeable contracts from OpenZeppelin v5.3.0, including:
    * `AccessControlUpgradeable`
    * `ERC20PausableUpgradeable`
    * `Initializable`
    * `UUPSUpgradeable`
    * `ReentrancyGuardUpgradeable`
    * `ContextUpgradeable`
    * `ERC165Upgradeable`
    * Standard OpenZeppelin contracts like `EnumerableSet` are also used.
* **Testing and Coverage**:
    * Comprehensive test suites are in place (as indicated by `T3System.test.js` and `mochaOutput.json`).
    * Code coverage reports (`coverage.json` and HTML reports) are generated, showing high coverage for implemented functionalities in `T3Token.sol` and `CustodianRegistry.sol`.
* **Deployment**:
    * Scripts for deployment are provided (e.g., `deploy.js`, `deployT3TokenAVAX.js`), including configurations for Hardhat and specific networks like Fuji (Avalanche testnet) and Sepolia.
    * Gas reports (`gasReport.md`, `gasReport.txt`) are available to analyze deployment and method execution costs.
* **Configuration**:
    * `hardhat.config.js` includes settings for the Solidity compiler, optimizer, default network, and network-specific configurations (RPC URLs, chain IDs, private keys via `.env`).
    * Etherscan/Snowtrace API keys are configured for contract verification.

This release provides a foundational system for the T3 digital currency, emphasizing security, regulatory considerations (KYC via custodians), and flexible tokenomics through its advanced fee and HalfLife mechanisms.
