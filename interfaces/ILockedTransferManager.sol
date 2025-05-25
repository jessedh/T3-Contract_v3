// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ILockedTransferManager
 * @dev Interface for the LockedTransferManager contract.
 * Defines external functions for managing time-locked transfers.
 */
interface ILockedTransferManager {
    // --- Custom Errors ---
    error ErrorLockedTransferNotFound();
    error ErrorLockedTransferAlreadyReleased();
    error ErrorLockedTransferAlreadyCancelled();
    error ErrorHashCommitmentMismatch();
    error ErrorReleaseNotAuthorized();
    error ErrorTransferNotCancellable();
    error ErrorTransferNotReleasable();
    error ErrorZeroAddress();
    error ErrorAmountZero();

    // --- Data Structures ---
    struct LockedTransfer {
        address sender;
        address recipient;
        uint256 amount; // Amount to be released
        bytes32 hashCommitment; // keccak256(abi.encodePacked(revealedFragment, nonce))
        bytes32 nonce; // Unique random value for this lock
        address releaseAuthorizedAddress; // Custodian wallet authorized to reveal
        bool isReleased;
        bool isCancelled; // For potential cancellation by sender/admin
    }

    // --- Events ---
    event LockedTransferCreated(bytes32 indexed transferId, address indexed sender, address indexed recipient, uint256 amount, address releaseAuthorizedAddress);
    event LockedTransferReleased(bytes32 indexed transferId, address indexed recipient, uint256 amount);
    event LockedTransferCancelled(bytes32 indexed transferId);

    // --- Functions ---
    /**
     * @dev Creates a new time-locked transfer.
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
    ) external returns (bytes32);

    /**
     * @dev Releases a time-locked transfer.
     * @param _transferId The ID of the locked transfer.
     * @param _revealedFragment The fragment needed to complete the hash commitment.
     * @return True if the release was successful.
     */
    function releaseLockedTransfer(bytes32 _transferId, bytes32 _revealedFragment) external returns (bool);

    /**
     * @dev Cancels a time-locked transfer.
     * @param _transferId The ID of the locked transfer.
     * @return True if the cancellation was successful.
     */
    function cancelLockedTransfer(bytes32 _transferId) external returns (bool);

    /**
     * @dev Returns the details of a locked transfer.
     * @param _transferId The ID of the locked transfer.
     * @return The LockedTransfer struct.
     */
    function getLockedTransfer(bytes32 _transferId) external view returns (LockedTransfer memory);
}
