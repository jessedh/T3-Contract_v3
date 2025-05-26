// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "interfaces/ILockedTransferManager.sol";
import "interfaces/ITokenConstants.sol";

/**
 * @title LockedTransferManager
 * @dev Manages time-locked transfers using a hash-based mapping system.
 * Optimized for gas efficiency and reduced contract size.
 */
contract LockedTransferManager is Initializable, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, ILockedTransferManager {

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant TOKEN_ROLE = keccak256("TOKEN_ROLE");

    // --- Mappings ---
    mapping(bytes32 => LockedTransfer) public lockedTransfers; // transferId => LockedTransfer

    // Reference to the T3Token contract
    address private immutable _t3TokenAddress;

    // Storage gap for future upgrades
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address t3TokenAddress) {
        _disableInitializers();
        
        // Store token address as immutable
        require(t3TokenAddress != address(0), "T3Token address cannot be zero");
        _t3TokenAddress = t3TokenAddress;
    }

    function initialize(address initialAdmin) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
        _grantRole(TOKEN_ROLE, _t3TokenAddress);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    /**
     * @dev Creates a new time-locked transfer using a hash-based ID.
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
    ) external override onlyRole(TOKEN_ROLE) nonReentrant whenNotPaused returns (bytes32) {
        if (_sender == address(0) || _recipient == address(0) || _releaseAuthorizedAddress == address(0)) revert ErrorZeroAddress();
        if (_amount == 0) revert ErrorAmountZero();

        // Generate transfer ID directly from parameters instead of using a counter
        bytes32 transferId = keccak256(abi.encodePacked(_sender, _recipient, _amount, _hashCommitment, _nonce, block.timestamp));
        
        // Ensure this ID hasn't been used before
        if (lockedTransfers[transferId].sender != address(0)) {
            // Extremely unlikely collision, but handle it by adding a random salt
            transferId = keccak256(abi.encodePacked(transferId, blockhash(block.number - 1)));
        }
        
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
    function releaseLockedTransfer(bytes32 _transferId, bytes32 _revealedFragment) 
        external 
        override 
        nonReentrant 
        whenNotPaused 
        returns (bool) 
    {
        LockedTransfer storage transfer_ = lockedTransfers[_transferId];

        if (transfer_.sender == address(0)) revert ErrorLockedTransferNotFound();
        if (transfer_.isReleased) revert ErrorLockedTransferAlreadyReleased();
        if (transfer_.isCancelled) revert ErrorLockedTransferAlreadyCancelled();
        if (_msgSender() != transfer_.releaseAuthorizedAddress) revert ErrorReleaseNotAuthorized();
        if (keccak256(abi.encodePacked(_revealedFragment, transfer_.nonce)) != transfer_.hashCommitment) revert ErrorHashCommitmentMismatch();

        // Mark as released before external call to prevent reentrancy
        transfer_.isReleased = true;
        
        // Transfer tokens from sender to recipient directly
        // This assumes the T3Token has approved this contract to transfer on its behalf
        bool success = ERC20Upgradeable(_t3TokenAddress).transferFrom(
            transfer_.sender, 
            transfer_.recipient, 
            transfer_.amount
        );
        
        require(success, "Token transfer failed");
        
        emit LockedTransferReleased(_transferId, transfer_.recipient, transfer_.amount);
        return true;
    }

    /**
     * @dev Cancels a time-locked transfer.
     * Can be called by the sender or an admin role.
     * @param _transferId The ID of the locked transfer.
     * @return True if the cancellation was successful.
     */
    function cancelLockedTransfer(bytes32 _transferId) 
        external 
        override 
        nonReentrant 
        whenNotPaused 
        returns (bool) 
    {
        LockedTransfer storage transfer_ = lockedTransfers[_transferId];

        if (transfer_.sender == address(0)) revert ErrorLockedTransferNotFound();
        if (transfer_.isReleased) revert ErrorLockedTransferAlreadyReleased();
        if (transfer_.isCancelled) revert ErrorLockedTransferAlreadyCancelled();
        if (_msgSender() != transfer_.sender && !hasRole(ADMIN_ROLE, _msgSender())) revert ErrorTransferNotCancellable();

        // Mark as cancelled
        transfer_.isCancelled = true;
        
        emit LockedTransferCancelled(_transferId);
        return true;
    }

    /**
     * @dev Batch releases multiple locked transfers in a single transaction.
     * @param _transferIds Array of transfer IDs to release.
     * @param _revealedFragments Array of revealed fragments for each transfer.
     * @return Array of booleans indicating success for each release.
     */
    function batchReleaseLockedTransfers(
        bytes32[] calldata _transferIds,
        bytes32[] calldata _revealedFragments
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (bool[] memory) 
    {
        uint256 length = _transferIds.length;
        require(length == _revealedFragments.length, "Array length mismatch");
        
        bool[] memory results = new bool[](length);
        
        for (uint256 i = 0; i < length;) {
            bytes32 transferId = _transferIds[i];
            bytes32 revealedFragment = _revealedFragments[i];
            
            LockedTransfer storage transfer_ = lockedTransfers[transferId];
            
            // Check all conditions
            if (transfer_.sender == address(0) || 
                transfer_.isReleased || 
                transfer_.isCancelled || 
                _msgSender() != transfer_.releaseAuthorizedAddress ||
                keccak256(abi.encodePacked(revealedFragment, transfer_.nonce)) != transfer_.hashCommitment) {
                results[i] = false;
            } else {
                // Mark as released
                transfer_.isReleased = true;
                
                // Transfer tokens
                bool success = ERC20Upgradeable(_t3TokenAddress).transferFrom(
                    transfer_.sender, 
                    transfer_.recipient, 
                    transfer_.amount
                );
                
                results[i] = success;
                
                if (success) {
                    emit LockedTransferReleased(transferId, transfer_.recipient, transfer_.amount);
                }
            }
            
            unchecked { ++i; }
        }
        
        return results;
    }

    /**
     * @dev Returns the details of a locked transfer.
     * @param _transferId The ID of the locked transfer.
     * @return The LockedTransfer struct.
     */
    function getLockedTransfer(bytes32 _transferId) external view override returns (LockedTransfer memory) {
        return lockedTransfers[_transferId];
    }

    // Pause/Unpause functions
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
