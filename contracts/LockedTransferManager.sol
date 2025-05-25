// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol"; // For _transfer, if this contract will handle actual token transfers
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol"; // Import PausableUpgradeable

import "../interfaces/ILockedTransferManager.sol"; // Corrected import path for ILockedTransferManager.sol

/**
 * @title LockedTransferManager
 * @dev Manages time-locked transfers using a fractionalized hash system.
 * This contract is designed to be deployed separately to reduce the main token contract's size.
 */
contract LockedTransferManager is Initializable, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, ILockedTransferManager { // Added PausableUpgradeable to inheritance list

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE"); // Assuming pausable functionality might be needed

    // --- Mappings ---
    mapping(bytes32 => LockedTransfer) public lockedTransfers; // transferId => LockedTransfer
    uint256 private nextLockedTransferId; // Counter for unique locked transfer IDs

    // Reference to the T3Token contract (if it needs to call back for transfers)
    ERC20Upgradeable private t3Token; // Using ERC20Upgradeable to call _transfer

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialAdmin, address _t3TokenAddress) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init(); // Initialize PausableUpgradeable

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin); // Grant pauser role if needed

        nextLockedTransferId = 1;
        require(_t3TokenAddress != address(0), "T3Token address cannot be zero");
        t3Token = ERC20Upgradeable(_t3TokenAddress);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    /**
     * @dev Creates a new time-locked transfer.
     * This function would typically be called by the T3Token contract.
     * @param _sender The address initiating the locked transfer.
     * @param _recipient The recipient of the locked transfer.
     * @param _amount The amount to be locked.
     * @param _hashCommitment The hash commitment for the release.
     * @param _nonce The unique nonce for this transfer.
     * @param _releaseAuthorizedAddress The address authorized to release the transfer.
     * @return The unique ID of the created locked transfer.
     */
    function createLockedTransfer(
        address _sender,
        address _recipient,
        uint256 _amount,
        bytes32 _hashCommitment,
        bytes32 _nonce,
        address _releaseAuthorizedAddress
    ) external override onlyRole(ADMIN_ROLE) nonReentrant returns (bytes32) { // Only admin/T3Token can create
        // Placeholder for actual logic:
        // In a real scenario, T3Token would transfer tokens to this contract first,
        // or this contract would instruct T3Token to transfer.
        // For now, we'll just record the transfer.

        if (_sender == address(0) || _recipient == address(0) || _releaseAuthorizedAddress == address(0)) revert ErrorZeroAddress();
        if (_amount == 0) revert ErrorAmountZero();

        bytes32 transferId = keccak256(abi.encodePacked(nextLockedTransferId, _sender, _recipient, _amount, block.timestamp));
        
        lockedTransfers[transferId] = LockedTransfer({
            sender: _sender,
            recipient: _recipient,
            amount: _amount,
            hashCommitment: _hashCommitment,
            nonce: _nonce,
            releaseAuthorizedAddress: _releaseAuthorizedAddress,
            isReleased: false,
            isCancelled: false
        });

        nextLockedTransferId++; // Increment for the next transfer

        emit LockedTransferCreated(transferId, _sender, _recipient, _amount, _releaseAuthorizedAddress);
        return transferId;
    }

    /**
     * @dev Releases a time-locked transfer.
     * Only the `releaseAuthorizedAddress` can call this.
     * @param _transferId The ID of the locked transfer.
     * @param _revealedFragment The fragment needed to complete the hash commitment.
     * @return True if the release was successful.
     */
    function releaseLockedTransfer(bytes32 _transferId, bytes32 _revealedFragment) external override nonReentrant returns (bool) {
        LockedTransfer storage transfer_ = lockedTransfers[_transferId];

        if (transfer_.sender == address(0)) revert ErrorLockedTransferNotFound(); // Check if transfer exists
        if (transfer_.isReleased) revert ErrorLockedTransferAlreadyReleased();
        if (transfer_.isCancelled) revert ErrorLockedTransferAlreadyCancelled();
        if (_msgSender() != transfer_.releaseAuthorizedAddress) revert ErrorReleaseNotAuthorized();
        if (keccak256(abi.encodePacked(_revealedFragment, transfer_.nonce)) != transfer_.hashCommitment) revert ErrorHashCommitmentMismatch();

        // Placeholder for actual token transfer logic
        // In a real scenario, this contract would transfer tokens from its balance
        // (which were previously sent by T3Token or directly) to the recipient.
        // For now, we'll simulate the transfer.
        // Example: t3Token.transfer(transfer_.recipient, transfer_.amount);
        // This requires the LockedTransferManager to hold T3Tokens or have allowance.
        
        // For demonstration, we'll assume this contract holds the tokens and transfers them.
        t3Token.transfer(transfer_.recipient, transfer_.amount); // Assuming this contract holds the T3Tokens

        transfer_.isReleased = true;
        emit LockedTransferReleased(_transferId, transfer_.recipient, transfer_.amount);
        return true;
    }

    /**
     * @dev Cancels a time-locked transfer.
     * Can be called by the sender or an admin role.
     * @param _transferId The ID of the locked transfer.
     * @return True if the cancellation was successful.
     */
    function cancelLockedTransfer(bytes32 _transferId) external override nonReentrant returns (bool) {
        LockedTransfer storage transfer_ = lockedTransfers[_transferId];

        if (transfer_.sender == address(0)) revert ErrorLockedTransferNotFound(); // Check if transfer exists
        if (transfer_.isReleased) revert ErrorLockedTransferAlreadyReleased();
        if (transfer_.isCancelled) revert ErrorLockedTransferAlreadyCancelled();
        if (_msgSender() != transfer_.sender && !hasRole(ADMIN_ROLE, _msgSender())) revert ErrorTransferNotCancellable();

        // Placeholder for actual token return logic
        // In a real scenario, this contract would transfer tokens back to the sender.
        // Example: t3Token.transfer(transfer_.sender, transfer_.amount);
        t3Token.transfer(transfer_.sender, transfer_.amount); // Assuming this contract holds the T3Tokens

        transfer_.isCancelled = true;
        emit LockedTransferCancelled(_transferId);
        return true;
    }

    /**
     * @dev Returns the details of a locked transfer.
     * @param _transferId The ID of the locked transfer.
     * @return The LockedTransfer struct.
     */
    function getLockedTransfer(bytes32 _transferId) external view override returns (LockedTransfer memory) {
        return lockedTransfers[_transferId];
    }

    // Admin function to set the T3Token address if it changes (e.g., after T3Token upgrade)
    function setT3TokenAddress(address _newT3TokenAddress) external onlyRole(ADMIN_ROLE) {
        require(_newT3TokenAddress != address(0), "New T3Token address cannot be zero");
        t3Token = ERC20Upgradeable(_newT3TokenAddress);
    }

    // Pause/Unpause functions for this contract
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
