// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/**
 * @title CustodianRegistry - Upgradeable Version
 * @dev Manages the registration of user wallets custodied by authorized Financial Institutions (FIs).
 * Stores KYC status timestamps associated with registered wallets.
 * Optimized for gas efficiency and reduced contract size.
 */
contract CustodianRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable {

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");

    // --- Custom Errors ---
    error ZeroAddress();
    error KYCExpiryBeforeValidation();
    error WalletAlreadyRegistered();
    error NotRegisteredCustodian();
    error WalletNotRegistered();
    error AccessControlBadAdmin(address admin);

    // --- Data Structures ---
    // Optimized struct with smaller uint types for timestamps
    struct CustodyData {
        address custodian;           // Address of the FI acting as custodian
        uint40 kycValidatedTimestamp; // Timestamp when KYC was last validated (reduced from uint256)
        uint40 kycExpiresTimestamp;   // Timestamp when KYC validation expires (reduced from uint256)
        uint176 reserved;            // Reserved space for future use, maintains full slot packing
    }

    // --- State Variables ---
    // Mapping from user address to their custody data
    mapping(address => CustodyData) private _custodyInfo;

    // --- Events ---
    // Indexed key parameters for more efficient off-chain filtering
    event WalletRegistered(address indexed userAddress, address indexed custodian, uint40 kycValidatedTimestamp, uint40 kycExpiresTimestamp);
    event WalletUnregistered(address indexed userAddress, address indexed custodian);
    event KYCStatusUpdated(address indexed userAddress, address indexed custodian, uint40 kycValidatedTimestamp, uint40 kycExpiresTimestamp);
    event BulkWalletsRegistered(address indexed custodian, uint256 count);

    // Storage gap for future upgrades
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract.
     * This function replaces the constructor for upgradeable contracts.
     * Grants ADMIN_ROLE and DEFAULT_ADMIN_ROLE to the initialAdmin.
     */
    function initialize(address initialAdmin) public initializer {
        if (initialAdmin == address(0)) {
            revert AccessControlBadAdmin(initialAdmin);
        }
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
    }

    /**
     * @dev Hook that is called by the UUPS proxy when an upgrade to a new implementation is requested.
     * Only accounts with ADMIN_ROLE can authorize an upgrade.
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(ADMIN_ROLE)
    {
        // This function intentionally left empty to allow upgrades authorized by ADMIN_ROLE.
    }

    // --- Role Management (by Admin) ---

    function grantCustodianRole(address fiAddress) external onlyRole(ADMIN_ROLE) {
        if (fiAddress == address(0)) revert ZeroAddress();
        _grantRole(CUSTODIAN_ROLE, fiAddress);
    }

    function revokeCustodianRole(address fiAddress) external onlyRole(ADMIN_ROLE) {
        if (fiAddress == address(0)) revert ZeroAddress();
        _revokeRole(CUSTODIAN_ROLE, fiAddress);
    }

    // --- Custodian Actions ---

    function registerCustodiedWallet(
        address userAddress,
        uint40 kycValidatedTimestamp,
        uint40 kycExpiresTimestamp
    ) external onlyRole(CUSTODIAN_ROLE) {
        if (userAddress == address(0)) revert ZeroAddress();
        if (kycExpiresTimestamp != 0 && kycExpiresTimestamp < kycValidatedTimestamp) revert KYCExpiryBeforeValidation();
        if (_custodyInfo[userAddress].custodian != address(0)) revert WalletAlreadyRegistered();

        address custodian = _msgSender();
        _custodyInfo[userAddress] = CustodyData({
            custodian: custodian,
            kycValidatedTimestamp: kycValidatedTimestamp,
            kycExpiresTimestamp: kycExpiresTimestamp,
            reserved: 0
        });

        emit WalletRegistered(userAddress, custodian, kycValidatedTimestamp, kycExpiresTimestamp);
    }

    /**
     * @dev Registers multiple wallets in a single transaction to save gas
     * @param userAddresses Array of wallet addresses to register
     * @param kycValidatedTimestamps Array of KYC validation timestamps
     * @param kycExpiresTimestamps Array of KYC expiry timestamps
     */
    function bulkRegisterWallets(
        address[] calldata userAddresses,
        uint40[] calldata kycValidatedTimestamps,
        uint40[] calldata kycExpiresTimestamps
    ) external onlyRole(CUSTODIAN_ROLE) {
        uint256 length = userAddresses.length;
        if (length != kycValidatedTimestamps.length || length != kycExpiresTimestamps.length) revert();
        
        address custodian = _msgSender();
        
        for (uint256 i = 0; i < length;) {
            address userAddress = userAddresses[i];
            uint40 validatedTimestamp = kycValidatedTimestamps[i];
            uint40 expiresTimestamp = kycExpiresTimestamps[i];
            
            if (userAddress == address(0)) revert ZeroAddress();
            if (expiresTimestamp != 0 && expiresTimestamp < validatedTimestamp) revert KYCExpiryBeforeValidation();
            if (_custodyInfo[userAddress].custodian != address(0)) revert WalletAlreadyRegistered();
            
            _custodyInfo[userAddress] = CustodyData({
                custodian: custodian,
                kycValidatedTimestamp: validatedTimestamp,
                kycExpiresTimestamp: expiresTimestamp,
                reserved: 0
            });
            
            emit WalletRegistered(userAddress, custodian, validatedTimestamp, expiresTimestamp);
            
            unchecked { ++i; }
        }
        
        emit BulkWalletsRegistered(custodian, length);
    }

    function updateKYCStatus(
        address userAddress,
        uint40 kycValidatedTimestamp,
        uint40 kycExpiresTimestamp
    ) external onlyRole(CUSTODIAN_ROLE) {
        if (userAddress == address(0)) revert ZeroAddress();
        address custodian = _msgSender();
        CustodyData storage data = _custodyInfo[userAddress];

        if (data.custodian != custodian) revert NotRegisteredCustodian();
        if (kycExpiresTimestamp != 0 && kycExpiresTimestamp < kycValidatedTimestamp) revert KYCExpiryBeforeValidation();

        data.kycValidatedTimestamp = kycValidatedTimestamp;
        data.kycExpiresTimestamp = kycExpiresTimestamp;

        emit KYCStatusUpdated(userAddress, custodian, kycValidatedTimestamp, kycExpiresTimestamp);
    }

    function unregisterCustodiedWallet(address userAddress) external onlyRole(CUSTODIAN_ROLE) {
        if (userAddress == address(0)) revert ZeroAddress();
        address custodian = _msgSender();
        CustodyData storage data = _custodyInfo[userAddress];

        if (data.custodian != custodian) revert NotRegisteredCustodian();
        if (data.custodian == address(0)) revert WalletNotRegistered();

        delete _custodyInfo[userAddress];
        emit WalletUnregistered(userAddress, custodian);
    }

    // --- View Functions ---

    function getCustodian(address userAddress) external view returns (address) {
        return _custodyInfo[userAddress].custodian;
    }

    function getKYCTimestamps(address userAddress) external view returns (uint40 validatedTimestamp, uint40 expiresTimestamp) {
        CustodyData storage data = _custodyInfo[userAddress];
        return (data.kycValidatedTimestamp, data.kycExpiresTimestamp);
    }

    /**
     * @dev Checks if a user's KYC is currently valid.
     * A wallet is considered approved if its KYC is valid OR if the address itself holds the CUSTODIAN_ROLE.
     * This function only checks for KYC validity of a client wallet.
     * For full approval check, T3Token will combine this with hasRole(CUSTODIAN_ROLE).
     */
    function isKYCValid(address userAddress) external view returns (bool) {
        CustodyData storage data = _custodyInfo[userAddress];
        // KYC is valid if:
        // 1. A custodian is registered for this address AND
        // 2. KYC validated timestamp is greater than 0 (meaning it was set) AND
        // 3. KYC has not expired (expiryTimestamp is 0 for no expiry, or >= current block.timestamp)
        return (
            data.custodian != address(0) &&
            data.kycValidatedTimestamp > 0 && 
            (data.kycExpiresTimestamp == 0 || data.kycExpiresTimestamp >= uint40(block.timestamp))
        );
    }

    // --- AccessControl Setup ---
    /**
     * @dev See {IERC165-supportsInterface}.
     */
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
