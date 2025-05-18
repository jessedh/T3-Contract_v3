// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24; // Keeping your pragma

// Using Upgradeable OpenZeppelin Contracts
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title CustodianRegistry - Upgradeable Version
 * @dev Manages the registration of user wallets custodied by authorized Financial Institutions (FIs).
 * Stores KYC status timestamps associated with registered wallets.
 * Uses AccessControlUpgradeable:
 * - ADMIN_ROLE: Can grant/revoke CUSTODIAN_ROLE to FIs.
 * - CUSTODIAN_ROLE: Granted to FIs, allows them to register/update wallets they custody.
 * Designed for UUPS proxy.
 */
contract CustodianRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");

    // --- Data Structures ---
    struct CustodyData {
        address custodian; // Address of the FI acting as custodian
        uint256 kycValidatedTimestamp; // Timestamp when KYC was last validated by custodian
        uint256 kycExpiresTimestamp;   // Timestamp when KYC validation expires (0 if never expires)
    }

    // --- State Variables ---
    // Mapping from user address to their custody data
    mapping(address => CustodyData) private _custodyInfo;

    // Optional: Keep track of all registered custodians for transparency
    EnumerableSet.AddressSet private _custodians;

    // --- Events ---
    event WalletRegistered(address indexed userAddress, address indexed custodian, uint256 kycValidatedTimestamp, uint256 kycExpiresTimestamp);
    event WalletUnregistered(address indexed userAddress, address indexed custodian);
    event KYCStatusUpdated(address indexed userAddress, address indexed custodian, uint256 kycValidatedTimestamp, uint256 kycExpiresTimestamp);

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
        onlyRole(ADMIN_ROLE) // Or DEFAULT_ADMIN_ROLE if preferred for upgrade control
    {
        // This function intentionally left empty to allow upgrades authorized by ADMIN_ROLE.
    }

    // --- Role Management (by Admin) ---

    function grantCustodianRole(address fiAddress) external onlyRole(ADMIN_ROLE) {
        require(fiAddress != address(0), "Custodian cannot be zero address");
        _grantRole(CUSTODIAN_ROLE, fiAddress);
        _custodians.add(fiAddress);
    }

    function revokeCustodianRole(address fiAddress) external onlyRole(ADMIN_ROLE) {
        require(fiAddress != address(0), "Custodian cannot be zero address");
        _revokeRole(CUSTODIAN_ROLE, fiAddress);
        _custodians.remove(fiAddress);
    }

    // --- Custodian Actions ---

    function registerCustodiedWallet(
        address userAddress,
        uint256 kycValidatedTimestamp,
        uint256 kycExpiresTimestamp
    ) external onlyRole(CUSTODIAN_ROLE) {
        require(userAddress != address(0), "User address cannot be zero");
        require(kycExpiresTimestamp == 0 || kycExpiresTimestamp >= kycValidatedTimestamp, "KYC expiry before validation");

        address custodian = _msgSender();
        _custodyInfo[userAddress] = CustodyData({
            custodian: custodian,
            kycValidatedTimestamp: kycValidatedTimestamp,
            kycExpiresTimestamp: kycExpiresTimestamp
        });

        emit WalletRegistered(userAddress, custodian, kycValidatedTimestamp, kycExpiresTimestamp);
    }

    function updateKYCStatus(
        address userAddress,
        uint256 kycValidatedTimestamp,
        uint256 kycExpiresTimestamp
    ) external onlyRole(CUSTODIAN_ROLE) {
        require(userAddress != address(0), "User address cannot be zero");
        address custodian = _msgSender();
        CustodyData storage data = _custodyInfo[userAddress];

        require(data.custodian == custodian, "Caller is not the registered custodian");
        require(kycExpiresTimestamp == 0 || kycExpiresTimestamp >= kycValidatedTimestamp, "KYC expiry before validation");

        data.kycValidatedTimestamp = kycValidatedTimestamp;
        data.kycExpiresTimestamp = kycExpiresTimestamp;

        emit KYCStatusUpdated(userAddress, custodian, kycValidatedTimestamp, kycExpiresTimestamp);
    }

    function unregisterCustodiedWallet(address userAddress) external onlyRole(CUSTODIAN_ROLE) {
        require(userAddress != address(0), "User address cannot be zero");
        address custodian = _msgSender();
        CustodyData storage data = _custodyInfo[userAddress];

        require(data.custodian == custodian, "Caller is not the registered custodian");

        delete _custodyInfo[userAddress];
        emit WalletUnregistered(userAddress, custodian);
    }

    // --- View Functions ---

    function getCustodian(address userAddress) external view returns (address) {
        return _custodyInfo[userAddress].custodian;
    }

    function getKYCTimestamps(address userAddress) external view returns (uint256 validatedTimestamp, uint256 expiresTimestamp) {
        CustodyData storage data = _custodyInfo[userAddress];
        return (data.kycValidatedTimestamp, data.kycExpiresTimestamp);
    }

    function isKYCValid(address userAddress) external view returns (bool) {
        CustodyData storage data = _custodyInfo[userAddress];
        return (data.kycValidatedTimestamp > 0 && (data.kycExpiresTimestamp == 0 || data.kycExpiresTimestamp >= block.timestamp));
    }

    // --- Optional: Functions for tracking custodians ---

    function custodianCount() external view returns (uint256) {
        return _custodians.length();
    }

    function custodianAtIndex(uint256 index) external view returns (address) {
        return _custodians.at(index);
    }

    // --- AccessControl Setup ---
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlUpgradeable) // Corrected for direct parents
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}