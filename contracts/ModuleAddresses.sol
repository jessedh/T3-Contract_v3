// filepath: contracts/ModuleAddresses.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract ModuleAddresses {
    address public immutable custodianRegistry;
    address public immutable lockedTransferManager;
    address public immutable interbankLiabilityLedger;
    
    constructor(
        address _custodianRegistry,
        address _lockedTransferManager,
        address _interbankLiabilityLedger
    ) {
        require(_custodianRegistry != address(0), "CustodianRegistry cannot be zero address");
        require(_lockedTransferManager != address(0), "LockedTransferManager cannot be zero address");
        require(_interbankLiabilityLedger != address(0), "InterbankLiabilityLedger cannot be zero address");
        
        custodianRegistry = _custodianRegistry;
        lockedTransferManager = _lockedTransferManager;
        interbankLiabilityLedger = _interbankLiabilityLedger;
    }
}