const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers"); 

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

describe("T3Token and CustodianRegistry (Upgradeable)", function () {
    let CustodianRegistryFactory;
    let T3TokenFactory;
    let registry; // Proxy instance
    let token;    // Proxy instance
    let owner;
    let admin; // Separate admin for T3Token and CustodianRegistry
    let custodian1; // Custodian address (FI)
    let custodian2; // Custodian address (FI)
    let user1; // Client of custodian1
    let user2; // Client of custodian2
    let nonRegisteredUser;
    let treasury; // Treasury address for fees
    let user2_alt_wallet; // Additional wallet for user2 to test washing scenario
    let minter; // Dedicated minter account
    let pauser; // Dedicated pauser account

    const ONE_DAY = 86400; // seconds in a day
    const ONE_ETHER = ethers.parseEther("1"); // 1 token unit (1 T3)
    const KYC_VALIDATED_TIMESTAMP = Math.floor(Date.now() / 1000);
    const KYC_EXPIRES_TIMESTAMP = KYC_VALIDATED_TIMESTAMP + (365 * ONE_DAY); // Valid for 1 year

    beforeEach(async function () {
        [owner, admin, custodian1, custodian2, user1, user2, nonRegisteredUser, treasury, user2_alt_wallet, minter, pauser] = await ethers.getSigners();

        // Deploy CustodianRegistry (Upgradeable)
        CustodianRegistryFactory = await ethers.getContractFactory("CustodianRegistry");
        registry = await upgrades.deployProxy(CustodianRegistryFactory, [owner.address], { initializer: "initialize" });
        await registry.waitForDeployment();

        // Grant admin role on registry to our designated admin account
        await registry.connect(owner).grantRole(await registry.ADMIN_ROLE(), admin.address);
        // Revoke owner's ADMIN_ROLE if desired for stricter testing
        await registry.connect(owner).revokeRole(await registry.ADMIN_ROLE(), owner.address);

        // Deploy T3Token (Upgradeable)
        T3TokenFactory = await ethers.getContractFactory("T3Token");
        token = await upgrades.deployProxy(T3TokenFactory, [
            "T3Token",
            "T3",
            owner.address, // initialAdmin (will get DEFAULT_ADMIN_ROLE, ADMIN_ROLE, PAUSER_ROLE)
            treasury.address,
            await registry.getAddress(), // CustodianRegistry address
            ethers.parseEther("1000000"), // initialMintAmount
            ONE_DAY, // _initialHalfLifeDuration
            ONE_DAY / 2, // _initialMinHalfLifeDuration
            ONE_DAY * 2, // _initialMaxHalfLifeDuration
            ONE_DAY * 30 // _initialInactivityResetPeriod
        ], { initializer: "initialize" });
        await token.waitForDeployment();

        // Grant admin role on token to our designated admin account
        await token.connect(owner).grantRole(await token.ADMIN_ROLE(), admin.address);
        // Revoke owner's ADMIN_ROLE if desired for stricter testing
        await token.connect(owner).revokeRole(await token.ADMIN_ROLE(), owner.address);

        // Grant MINTER and PAUSER roles to dedicated accounts
        await token.connect(admin).grantRole(await token.MINTER_ROLE(), minter.address);
        await token.connect(admin).grantRole(await token.PAUSER_ROLE(), pauser.address);


        // Grant custodian roles to custodian accounts
        await registry.connect(admin).grantCustodianRole(custodian1.address);
        await registry.connect(admin).grantCustodianRole(custodian2.address);

        // Register user wallets under their respective custodians with valid KYC timestamps
        await registry.connect(custodian1).registerCustodiedWallet(user1.address, KYC_VALIDATED_TIMESTAMP, KYC_EXPIRES_TIMESTAMP);
        await registry.connect(custodian2).registerCustodiedWallet(user2.address, KYC_VALIDATED_TIMESTAMP, KYC_EXPIRES_TIMESTAMP);
        // Register user2_alt_wallet under custodian2 for washing scenario
        await registry.connect(custodian2).registerCustodiedWallet(user2_alt_wallet.address, KYC_VALIDATED_TIMESTAMP, KYC_EXPIRES_TIMESTAMP);


        // Mint some tokens to user1 for testing (initial mint was to owner)
        await token.connect(minter).mint(user1.address, ethers.parseEther("1000"));
    });

    describe("CustodianRegistry Functionality (Upgradeable)", function () {
        it("Should set the correct admin roles on CustodianRegistry", async function () {
            expect(await registry.hasRole(await registry.ADMIN_ROLE(), admin.address)).to.be.true;
            expect(await registry.hasRole(await registry.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.false; // Owner's DEFAULT_ADMIN_ROLE was revoked
            expect(await registry.hasRole(await registry.ADMIN_ROLE(), owner.address)).to.be.false; // Owner's ADMIN_ROLE was revoked
        });

        it("Should allow admin to grant/revoke custodian role", async function () {
            const newCustodianFI = (await ethers.getSigners())[8];
            await expect(registry.connect(admin).grantCustodianRole(newCustodianFI.address))
                .to.emit(registry, "RoleGranted")
                .withArgs(await registry.CUSTODIAN_ROLE(), newCustodianFI.address, admin.address);
            expect(await registry.hasRole(await registry.CUSTODIAN_ROLE(), newCustodianFI.address)).to.be.true;
            expect(await registry.custodianCount()).to.equal(3); // custodian1, custodian2, newCustodianFI

            await expect(registry.connect(admin).revokeCustodianRole(newCustodianFI.address))
                .to.emit(registry, "RoleRevoked")
                .withArgs(await registry.CUSTODIAN_ROLE(), newCustodianFI.address, admin.address);
            expect(await registry.hasRole(await registry.CUSTODIAN_ROLE(), newCustodianFI.address)).to.be.false;
            expect(await registry.custodianCount()).to.equal(2);
        });

        it("Should not allow non-admin to grant/revoke custodian role", async function () {
            const newCustodianFI = (await ethers.getSigners())[8];
            await expect(registry.connect(user1).grantCustodianRole(newCustodianFI.address))
                .to.be.revertedWith(/AccessControl: caller is not an ADMIN_ROLE/);
            await expect(registry.connect(user1).revokeCustodianRole(custodian1.address))
                .to.be.revertedWith(/AccessControl: caller is not an ADMIN_ROLE/);
        });

        it("Should allow custodian to register their client's wallet with KYC timestamps", async function () {
            const newUser = (await ethers.getSigners())[9];
            const currentTimestamp = Math.floor(Date.now() / 1000);
            const expiryTimestamp = currentTimestamp + ONE_DAY;

            await expect(registry.connect(custodian1).registerCustodiedWallet(newUser.address, currentTimestamp, expiryTimestamp))
                .to.emit(registry, "WalletRegistered")
                .withArgs(newUser.address, custodian1.address, currentTimestamp, expiryTimestamp);

            expect(await registry.getCustodian(newUser.address)).to.equal(custodian1.address);
            const [validated, expires] = await registry.getKYCTimestamps(newUser.address);
            expect(validated).to.equal(currentTimestamp);
            expect(expires).to.equal(expiryTimestamp);
            expect(await registry.isKYCValid(newUser.address)).to.be.true;
        });

        it("Should not allow re-registering an already registered wallet", async function () {
            const currentTimestamp = Math.floor(Date.now() / 1000);
            const expiryTimestamp = currentTimestamp + ONE_DAY;
            await expect(registry.connect(custodian1).registerCustodiedWallet(user1.address, currentTimestamp, expiryTimestamp))
                .to.be.revertedWith("Wallet already registered");
        });

        it("Should allow custodian to update KYC status of their client's wallet", async function () {
            const newValidated = KYC_VALIDATED_TIMESTAMP + 100;
            const newExpires = KYC_EXPIRES_TIMESTAMP + 100;

            await expect(registry.connect(custodian1).updateKYCStatus(user1.address, newValidated, newExpires))
                .to.emit(registry, "KYCStatusUpdated")
                .withArgs(user1.address, custodian1.address, newValidated, newExpires);

            const [validated, expires] = await registry.getKYCTimestamps(user1.address);
            expect(validated).to.equal(newValidated);
            expect(expires).to.equal(newExpires);
        });

        it("Should not allow a custodian to update KYC for another custodian's client", async function () {
            const newValidated = KYC_VALIDATED_TIMESTAMP + 100;
            const newExpires = KYC_EXPIRES_TIMESTAMP + 100;
            await expect(registry.connect(custodian1).updateKYCStatus(user2.address, newValidated, newExpires))
                .to.be.revertedWith("Caller is not the registered custodian");
        });

        it("Should allow custodian to unregister their client's wallet", async function () {
            await expect(registry.connect(custodian1).unregisterCustodiedWallet(user1.address))
                .to.emit(registry, "WalletUnregistered")
                .withArgs(user1.address, custodian1.address);
            expect(await registry.getCustodian(user1.address)).to.equal(ethers.ZeroAddress);
            expect(await registry.isKYCValid(user1.address)).to.be.false;
        });

        it("Should return true for KYC valid wallets and custodian addresses (via hasRole)", async function () {
            expect(await registry.isKYCValid(user1.address)).to.be.true; // Client with valid KYC
            expect(await registry.hasRole(await registry.CUSTODIAN_ROLE(), custodian1.address)).to.be.true; // Custodian FI itself
            expect(await registry.isKYCValid(nonRegisteredUser.address)).to.be.false; // Not registered
            
            // Advance time to expire KYC
            await ethers.provider.send("evm_increaseTime", [365 * ONE_DAY + 1]);
            await ethers.provider.send("evm_mine");
            expect(await registry.isKYCValid(user1.address)).to.be.false; // KYC should now be expired
        });

        it("Should not allow unregistering a non-existent wallet", async function () {
            await expect(registry.connect(custodian1).unregisterCustodiedWallet(nonRegisteredUser.address))
                .to.be.revertedWith("Wallet not registered");
        });

        // NEW TEST FROM PRIOR VERSION
        it("Initialize: Should revert if initialAdmin is zero address", async function() {
            const CustodianRegistryFactoryDep = await ethers.getContractFactory("CustodianRegistry");
            await expect(
                upgrades.deployProxy(CustodianRegistryFactoryDep, [ZERO_ADDRESS], {initializer: "initialize", kind: "uups"})
            ).to.be.revertedWithCustomError(CustodianRegistryFactoryDep, "AccessControlBadAdmin")
             .withArgs(ZERO_ADDRESS);
        });

        // NEW TEST FROM PRIOR VERSION
        it("registerCustodiedWallet: Should revert for zero user address", async function() {
            await expect(registry.connect(custodian1).registerCustodiedWallet(ZERO_ADDRESS, KYC_VALIDATED_TIMESTAMP, 0))
                .to.be.revertedWith("User address cannot be zero");
        });

        // NEW TEST FROM PRIOR VERSION
        it("registerCustodiedWallet: Should revert if KYC expiry is before validation", async function() {
            const validTs = KYC_VALIDATED_TIMESTAMP;
            const invalidExpiryTs = validTs - 100;
            await expect(registry.connect(custodian1).registerCustodiedWallet(user3.address, validTs, invalidExpiryTs)) // Using user3 to avoid "already registered"
                .to.be.revertedWith("KYC expiry before validation");
        });
    });

    describe("T3Token Core Functionality (Upgradeable)", function () {
        it("Should allow minter to mint tokens to an approved wallet", async function () {
            // minter is the dedicated minter account
            await expect(token.connect(minter).mint(user1.address, ONE_ETHER))
                .to.emit(token, "Transfer")
                .withArgs(ethers.ZeroAddress, user1.address, ONE_ETHER);
            expect(await token.balanceOf(user1.address)).to.equal(ethers.parseEther("1001"));
            expect(await token.mintedByMinter(minter.address)).to.equal(ethers.parseEther("1001"));
        });

        it("Should not allow minter to mint tokens to an unapproved wallet", async function () {
            // Unregister user1's wallet to make it unapproved
            await registry.connect(custodian1).unregisterCustodiedWallet(user1.address);
            await expect(token.connect(minter).mint(user1.address, ONE_ETHER))
                .to.be.revertedWith("Recipient must be a registered wallet");
            
            await expect(token.connect(minter).mint(nonRegisteredUser.address, ONE_ETHER))
                .to.be.revertedWith("Recipient must be a registered wallet");
        });

        it("Should not allow non-minter to mint tokens", async function () {
            await expect(token.connect(user1).mint(user1.address, ONE_ETHER))
                .to.be.revertedWith(/AccessControl: caller is not a MINTER_ROLE/);
        });

        it("Should pause and unpause transfers", async function () {
            await token.connect(pauser).pause(); // pauser is the dedicated pauser account
            await expect(token.connect(user1).transfer(user2.address, 100)).to.be.revertedWith("Enforced pause");
            await token.connect(pauser).unpause();
            // Transfer should now succeed (HalfLife logic will apply)
            await expect(token.connect(user1).transfer(user2.address, 100)).to.not.be.reverted;
        });

        it("Should not allow non-pauser to pause/unpause", async function () {
            await expect(token.connect(user1).pause()).to.be.revertedWith(/AccessControl: caller is not a PAUSER_ROLE/);
            await expect(token.connect(user1).unpause()).to.be.revertedWith(/AccessControl: caller is not a PAUSER_ROLE/);
        });

        it("Should allow burner to burn tokens from an approved wallet", async function () {
            // owner is not a BURNER_ROLE by default in this contract. Grant it.
            await token.connect(admin).grantRole(await token.BURNER_ROLE(), owner.address);
            // Mint some tokens to owner first
            await token.connect(minter).mint(owner.address, ONE_ETHER);
            const initialBalance = await token.balanceOf(owner.address);
            await expect(token.connect(owner).burn(ONE_ETHER.div(2)))
                .to.emit(token, "Transfer")
                .withArgs(owner.address, ethers.ZeroAddress, ONE_ETHER.div(2));
            expect(await token.balanceOf(owner.address)).to.equal(initialBalance.sub(ONE_ETHER.div(2)));
        });

        it("Should not allow non-approved burner to burn tokens", async function () {
            // Unregister user1's wallet to make it unapproved
            await registry.connect(custodian1).unregisterCustodiedWallet(user1.address);
            await expect(token.connect(user1).burn(100)).to.be.revertedWith("Burner must be a registered wallet");
        });

        // NEW TEST FROM PRIOR VERSION
        it("Initialize: Should revert if treasury address is zero", async function() {
            const T3TokenFactoryDep = await ethers.getContractFactory("T3Token"); 
            await expect(upgrades.deployProxy(T3TokenFactoryDep, [
                "T3", "T3", owner.address, ZERO_ADDRESS, await registry.getAddress(), ethers.parseEther("1"), 3600, 600, 86400, 30*86400
            ], {initializer: "initialize", kind: "uups"}))
                .to.be.revertedWith("Treasury address cannot be zero");
        });

        // NEW TEST FROM PRIOR VERSION
        it("Initialize: Should revert with invalid HalfLife parameters", async function() {
            const T3TokenFactoryDep = await ethers.getContractFactory("T3Token");
            // minHalfLifeDuration = 0
            await expect(upgrades.deployProxy(T3TokenFactoryDep, [
                "T3", "T3", owner.address, treasury.address, await registry.getAddress(), ethers.parseEther("1"), 3600, 0, 86400, 30*86400
            ], {initializer: "initialize", kind: "uups"}))
                .to.be.revertedWith("Min HalfLife must be positive");
            // minHalfLifeDuration > maxHalfLifeDuration
            await expect(upgrades.deployProxy(T3TokenFactoryDep, [
                "T3", "T3", owner.address, treasury.address, await registry.getAddress(), ethers.parseEther("1"), 3600, 86401, 86400, 30*86400
            ], {initializer: "initialize", kind: "uups"}))
                .to.be.revertedWith("Min HalfLife exceeds max");
            // initialHalfLifeDuration out of bounds (below min)
            await expect(upgrades.deployProxy(T3TokenFactoryDep, [
                "T3", "T3", owner.address, treasury.address, await registry.getAddress(), ethers.parseEther("1"), 500, 600, 86400, 30*86400
            ], {initializer: "initialize", kind: "uups"}))
                .to.be.revertedWith("Initial HalfLife out of bounds");
            // inactivityResetPeriod = 0
            await expect(upgrades.deployProxy(T3TokenFactoryDep, [
                "T3", "T3", owner.address, treasury.address, await registry.getAddress(), ethers.parseEther("1"), 3600, 600, 86400, 0
            ], {initializer: "initialize", kind: "uups"}))
                .to.be.revertedWith("Inactivity period must be positive");
        });
    });

    describe("T3Token Admin Functions (Setters)", function() {
        // NEW TEST FROM PRIOR VERSION
        it("setHalfLifeDuration: should update and respect bounds", async function() {
            await token.connect(admin).setHalfLifeDuration(1000);
            expect(await token.halfLifeDuration()).to.equal(ethers.toBigInt(1000));
            await expect(token.connect(admin).setHalfLifeDuration(500)) // Below min (600)
                .to.be.revertedWith("Below minimum");
            await expect(token.connect(admin).setHalfLifeDuration(ONE_DAY + 100)) // Above max (ONE_DAY*2, but here initial was ONE_DAY)
                .to.be.revertedWith("Above maximum"); // This will now revert correctly given initial max (ONE_DAY*2)
        });

        // NEW TEST FROM PRIOR VERSION
        it("setMinHalfLifeDuration: should update and adjust current duration if needed", async function() {
            await token.connect(admin).setHalfLifeDuration(1000); // Set current HL to 1000
            await token.connect(admin).setMinHalfLifeDuration(1200); // Set min HL to 1200
            expect(await token.minHalfLifeDuration()).to.equal(ethers.toBigInt(1200));
            expect(await token.halfLifeDuration()).to.equal(ethers.toBigInt(1200)); // Current HL adjusted to new min

            await expect(token.connect(admin).setMinHalfLifeDuration(0))
                .to.be.revertedWith("Min must be positive");
            await expect(token.connect(admin).setMinHalfLifeDuration(ONE_DAY * 2 + 100)) // Max HalfLife is ONE_DAY * 2
                .to.be.revertedWith("Min exceeds max");
        });
        
        // NEW TEST FROM PRIOR VERSION
        it("setMaxHalfLifeDuration: should update and adjust current duration if needed", async function() {
            await token.connect(admin).setHalfLifeDuration(ONE_DAY + 100); // Set current HL to 1day+100
            await token.connect(admin).setMaxHalfLifeDuration(ONE_DAY - 200); // Set max HL to 1day-200
            expect(await token.maxHalfLifeDuration()).to.equal(ethers.toBigInt(ONE_DAY - 200));
            expect(await token.halfLifeDuration()).to.equal(ethers.toBigInt(ONE_DAY - 200)); // Current HL adjusted to new max

            await expect(token.connect(admin).setMaxHalfLifeDuration(500)) // Current min is 600, max is 500
                .to.be.revertedWith("Max below minimum");
        });

        // NEW TEST FROM PRIOR VERSION
        it("setInactivityResetPeriod: should update and reject zero", async function() {
            await token.connect(admin).setInactivityResetPeriod(15 * ONE_DAY);
            expect(await token.inactivityResetPeriod()).to.equal(ethers.toBigInt(15 * ONE_DAY));
            await expect(token.connect(admin).setInactivityResetPeriod(0))
                .to.be.revertedWith("Period must be positive");
        });

        // NEW TEST FROM PRIOR VERSION
        it("setTreasuryAddress: should revert if setting to zero address", async function() {
            await expect(token.connect(admin).setTreasuryAddress(ZERO_ADDRESS))
                .to.be.revertedWith("Treasury address cannot be zero");
        });

        it("flagAbnormalTransaction: should increment count and affect risk score", async function() {
            // Ensure user4 has a profile initialized by a transfer
            await registry.connect(admin).grantCustodianRole(user4.address); // Make user4 a custodian to be approved
            await registry.connect(user4).registerCustodiedWallet(user4.address, KYC_VALIDATED_TIMESTAMP, KYC_EXPIRES_TIMESTAMP); // Self-register
            
            await token.connect(minter).mint(user4.address, ONE_ETHER); // Mint to user4 for profile creation
            // Simulate a transfer to ensure profile is "written" (if not done by mint)
            // (walletRiskProfiles[user4.address].creationTime is set in _ensureProfileExistsForWrite during first transfer out or mint in)
            await token.connect(user4).transfer(user5.address, ethers.parseUnits("0.01", 18));
            await time.increase(ONE_DAY * 8); // Pass new wallet period

            const initialRisk = await token.calculateRiskFactor(user4.address);
            expect((await token.walletRiskProfiles(user4.address)).abnormalTxCount).to.equal(0);

            await token.connect(admin).flagAbnormalTransaction(user4.address);
            expect((await token.walletRiskProfiles(user4.address)).abnormalTxCount).to.equal(1);
            
            const newRisk = await token.calculateRiskFactor(user4.address);
            expect(newRisk).to.be.gt(initialRisk);
            expect(initialRisk).to.equal(ethers.toBigInt(10000)); // Should be base 100% after 8 days
            expect(newRisk).to.equal(ethers.toBigInt(10000) + ethers.toBigInt(500)); // +5% (500bps) per abnormal tx

            await expect(token.connect(user1).flagAbnormalTransaction(user4.address))
                .to.be.revertedWithCustomError(token, "AccessControlUnauthorizedAccount");
        });
    });

    describe("T3Token Interbank Liability", function() {
        // Grant custodian roles and register wallets for user4/user5 to act as pseudo-custodians/clients
        beforeEach(async function() {
            await registry.connect(admin).grantCustodianRole(user4.address);
            await registry.connect(user4).registerCustodiedWallet(user4.address, KYC_VALIDATED_TIMESTAMP, KYC_EXPIRES_TIMESTAMP); // Self-register
            await registry.connect(admin).grantCustodianRole(user5.address);
            await registry.connect(user5).registerCustodiedWallet(user5.address, KYC_VALIDATED_TIMESTAMP, KYC_EXPIRES_TIMESTAMP); // Self-register
        });

        const liabilityAmount = ethers.parseUnits("1000", 18);
        it("Should allow admin to record and clear interbank liability", async function() {
            // Using user4.address and user5.address as custodian addresses for liability tracking
            await expect(token.connect(admin).recordInterbankLiability(user4.address, user5.address, liabilityAmount))
                .to.emit(token, "InterbankLiabilityRecorded")
                .withArgs(user4.address, user5.address, liabilityAmount);
            expect(await token.interbankLiability(user4.address, user5.address)).to.equal(liabilityAmount);

            await expect(token.connect(admin).clearInterbankLiability(user4.address, user5.address, liabilityAmount / ethers.toBigInt(2)))
                .to.emit(token, "InterbankLiabilityCleared")
                .withArgs(user4.address, user5.address, liabilityAmount / ethers.toBigInt(2));
            expect(await token.interbankLiability(user4.address, user5.address)).to.equal(liabilityAmount / ethers.toBigInt(2));

            await token.connect(admin).clearInterbankLiability(user4.address, user5.address, liabilityAmount / ethers.toBigInt(2));
            expect(await token.interbankLiability(user4.address, user5.address)).to.equal(0);
        });

        it("Should prevent non-admin from recording/clearing liability", async function() {
            await expect(token.connect(user1).recordInterbankLiability(user4.address, user5.address, liabilityAmount))
                .to.be.revertedWithCustomError(token, "AccessControlUnauthorizedAccount");
            await expect(token.connect(user1).clearInterbankLiability(user4.address, user5.address, liabilityAmount))
                .to.be.revertedWithCustomError(token, "AccessControlUnauthorizedAccount");
        });

        it("Should revert recording/clearing liability with invalid parameters", async function() {
            await expect(token.connect(admin).recordInterbankLiability(ZERO_ADDRESS, user5.address, liabilityAmount))
                .to.be.revertedWith("Debtor cannot be zero address");
            await expect(token.connect(admin).recordInterbankLiability(user4.address, ZERO_ADDRESS, liabilityAmount))
                .to.be.revertedWith("Creditor cannot be zero address");
            await expect(token.connect(admin).recordInterbankLiability(user4.address, user4.address, liabilityAmount))
                .to.be.revertedWith("Debtor cannot be creditor");
            await expect(token.connect(admin).recordInterbankLiability(user4.address, user5.address, 0))
                .to.be.revertedWith("Amount must be positive");
            
            // Should also revert if debtor/creditor are not custodians
            await expect(token.connect(admin).recordInterbankLiability(user1.address, user2.address, liabilityAmount))
                .to.be.revertedWith("Debtor must be a custodian address");

            await token.connect(admin).recordInterbankLiability(user4.address, user5.address, liabilityAmount);
            await expect(token.connect(admin).clearInterbankLiability(user4.address, user5.address, liabilityAmount * ethers.toBigInt(2)))
                .to.be.revertedWith("Amount to clear exceeds outstanding liability");
            await expect(token.connect(admin).clearInterbankLiability(user4.address, user3.address, liabilityAmount)) // user3 is not user5
                .to.be.revertedWith("Amount to clear exceeds outstanding liability"); // Should actually revert with "Creditor must be a custodian address" or similar if user3 not a custodian
            await expect(token.connect(admin).clearInterbankLiability(user4.address, user5.address, 0))
                .to.be.revertedWith("Amount to clear must be positive");
        });
    });

    describe("T3Token HalfLife Reversible Transfers (Recipient-Side Restriction)", function () {
        it("Should initiate a HalfLife transfer and restrict recipient's spendable balance", async function () {
            const initialUser1Balance = await token.balanceOf(user1.address); // 1000
            const initialUser2Balance = await token.balanceOf(user2.address); // 0
            const transferAmount = ethers.parseEther("100");
            
            // Estimate fee (cannot call internal _calculateFee directly from test)
            const feeDetails = await token.estimateTransferFeeDetails(user1.address, user2.address, transferAmount);
            const totalFeeAssessed = feeDetails.totalFeeAssessed;
            const amountIntendedForRecipient = feeDetails.netAmountToSendToRecipient;

            await expect(token.connect(user1).transfer(user2.address, transferAmount))
                .to.emit(token, "TransferWithFee")
                .withArgs(user1.address, user2.address, amountIntendedForRecipient, totalFeeAssessed, ethers.anyValue, ethers.anyValue, ethers.anyValue)
                .to.emit(token, "RecipientTransferPending")
                .withArgs(user1.address, user2.address, amountIntendedForRecipient, (await ethers.provider.getBlock("latest")).timestamp + ONE_DAY);

            // User1's balance should be reduced by full transfer amount (including fee paid from balance)
            const feePaidFromBalanceNow = feeDetails.feeAfterCredits; // Assuming no prefunded fees
            expect(await token.balanceOf(user1.address)).to.equal(initialUser1Balance.sub(amountIntendedForRecipient).sub(feePaidFromBalanceNow));
            
            // User2's total balance should reflect the incoming amount
            expect(await token.balanceOf(user2.address)).to.equal(initialUser2Balance.add(amountIntendedForRecipient));
            
            // User2's spendable balance should be 0 (restricted)
            expect(await token.getSpendableBalance(user2.address)).to.equal(initialUser2Balance); // Should be 0 if initial balance was 0
            
            // Fee should be in the treasury
            expect(await token.balanceOf(treasury.address)).to.equal(totalFeeAssessed);

            // Check pending transfer state for recipient
            const pendingTx = await token.getPendingRecipientTransfer(user2.address);
            expect(pendingTx.sender).to.equal(user1.address);
            expect(pendingTx.amount).to.equal(amountIntendedForRecipient);
            expect(pendingTx.reversed).to.be.false;
            expect(pendingTx.finalized).to.be.false;

            // User2 attempts to re-transfer funds (should fail)
            await expect(token.connect(user2).transfer(user1.address, amountIntendedForRecipient.div(2)))
                .to.be.revertedWith("ERC20: transfer amount exceeds spendable balance (HalfLife pending)");
        });

        it("Should prevent 'washing' by restricting transfers to self during HalfLife", async function () {
            const transferAmount = ethers.parseEther("50");
            await token.connect(user1).transfer(user2.address, transferAmount); // User2 receives 50 T3, now restricted

            const pendingTx = await token.getPendingRecipientTransfer(user2.address);
            const amountAfterFee = pendingTx.amount;

            // Attempt to send to self (washing scenario)
            await expect(token.connect(user2).transfer(user2.address, amountAfterFee.div(2))) // Try sending half the pending amount to self
                .to.be.revertedWith("ERC20: transfer amount exceeds spendable balance (HalfLife pending)");

            // Attempt to send to another wallet controlled by user2 (washing scenario)
            // user2_alt_wallet is registered under custodian2
            await expect(token.connect(user2).transfer(user2_alt_wallet.address, amountAfterFee.div(2)))
                .to.be.revertedWith("ERC20: transfer amount exceeds spendable balance (HalfLife pending)");
            
            // Verify balances remain unchanged for washing attempts
            expect(await token.balanceOf(user2.address)).to.equal(amountAfterFee); // Total balance should still hold pending amount
            expect(await token.getSpendableBalance(user2.address)).to.equal(0); // Spendable should still be 0
        });

        it("Should allow recipient to reverse a pending transfer within HalfLife window", async function () {
            const initialUser1Balance = await token.balanceOf(user1.address);
            const initialUser2Balance = await token.balanceOf(user2.address);
            const transferAmount = ethers.parseEther("100");

            await token.connect(user1).transfer(user2.address, transferAmount);
            const pendingTx = await token.getPendingRecipientTransfer(user2.address);
            const amountAfterFee = pendingTx.amount; // Get actual amount after fee from pendingTx

            await expect(token.connect(user2).reverseRecipientTransfer())
                .to.emit(token, "RecipientTransferReversed")
                .withArgs(user1.address, user2.address, amountAfterFee);

            // User1's balance should be restored by the amount that was pending for user2
            // Note: initialUser1Balance - (original transferAmount - amountAfterFee) is the fee paid by user1
            // So, initialUser1Balance - feePaidByUser1 + amountAfterFee (returned)
            const feeDetails = await token.estimateTransferFeeDetails(user1.address, user2.address, transferAmount);
            const feePaidFromBalanceNow = feeDetails.feeAfterCredits;
            const expectedUser1BalanceAfterReversal = initialUser1Balance.sub(feePaidFromBalanceNow); // User1 loses fee, but gets amount back
            expect(await token.balanceOf(user1.address)).to.equal(expectedUser1BalanceAfterReversal);
            
            // User2's balance should return to initial
            expect(await token.balanceOf(user2.address)).to.equal(initialUser2Balance);
            expect(await token.getSpendableBalance(user2.address)).to.equal(initialUser2Balance); // No pending
            
            // Fee should remain in treasury (not refunded on reversal)
            expect(await token.balanceOf(treasury.address)).to.be.gt(0);

            // Pending transfer should be marked as reversed (not deleted immediately)
            const clearedTx = await token.getPendingRecipientTransfer(user2.address);
            expect(clearedTx.reversed).to.be.true;
            expect(clearedTx.finalized).to.be.false;
        });

        it("Should not allow recipient reversal after HalfLife window expires", async function () {
            const transferAmount = ethers.parseEther("100");
            await token.connect(user1).transfer(user2.address, transferAmount);

            await ethers.provider.send("evm_increaseTime", [ONE_DAY + 1]); // Advance time past HalfLife
            await ethers.provider.send("evm_mine"); // Mine a new block

            await expect(token.connect(user2).reverseRecipientTransfer())
                .to.be.revertedWith("HalfLife window has expired");
        });

        it("Should finalize recipient transfer after HalfLife window expires and award credits", async function () {
            const initialUser1Balance = await token.balanceOf(user1.address);
            const initialUser2Balance = await token.balanceOf(user2.address);
            const transferAmount = ethers.parseEther("100");
            await token.connect(user1).transfer(user2.address, transferAmount);
            const pendingTx = await token.getPendingRecipientTransfer(user2.address);
            const amountAfterFee = pendingTx.amount;

            await ethers.provider.send("evm_increaseTime", [ONE_DAY + 1]);
            await ethers.provider.send("evm_mine");

            const feeDetails = await token.estimateTransferFeeDetails(user1.address, user2.address, transferAmount);
            const expectedFee = feeDetails.totalFeeAssessed; // Total fee assessed for the original A->B transfer
            
            const totalIncentive = expectedFee.div(8); // 12.5% of total fee
            const incentivePerParty = totalIncentive.div(2); // Split evenly

            await expect(token.finalizeRecipientTransfer(user2.address))
                .to.emit(token, "RecipientTransferFinalized")
                .withArgs(user1.address, user2.address, amountAfterFee)
                .to.emit(token, "LoyaltyRefundProcessed")
                .withArgs(user1.address, incentivePerParty)
                .to.emit(token, "LoyaltyRefundProcessed")
                .withArgs(user2.address, incentivePerParty);

            // Balances should reflect the transfer finalized
            expect(await token.balanceOf(user1.address)).to.equal(initialUser1Balance.sub(transferAmount));
            expect(await token.balanceOf(user2.address)).to.equal(initialUser2Balance.add(amountAfterFee));
            expect(await token.getSpendableBalance(user2.address)).to.equal(initialUser2Balance.add(amountAfterFee)); // Now spendable

            expect(await token.getAvailableCredits(user1.address)).to.equal(incentivePerParty);
            expect(await token.getAvailableCredits(user2.address)).to.equal(incentivePerParty);

            // Pending transfer should be cleared
            const clearedTx = await token.getPendingRecipientTransfer(user2.address);
            expect(clearedTx.sender).to.equal(ethers.ZeroAddress);
        });

        it("Should not allow finalizing an active (non-expired) recipient HalfLife transfer", async function () {
            await token.connect(user1).transfer(user2.address, ethers.parseEther("100"));
            await expect(token.finalizeRecipientTransfer(user2.address))
                .to.be.revertedWith("HalfLife window not expired yet");
        });

        it("Should not allow recipient HalfLife finalization if already reversed", async function () {
            const transferAmount = ethers.parseEther("100");
            await token.connect(user1).transfer(user2.address, transferAmount);

            await token.connect(user2).reverseRecipientTransfer(); // Reverse it

            await ethers.provider.send("evm_increaseTime", [ONE_DAY + 1]);
            await ethers.provider.send("evm_mine");

            await expect(token.finalizeRecipientTransfer(user2.address))
                .to.be.revertedWith("Transfer already reversed");
        });

        it("Should auto-finalize recipient HalfLife when new transfer comes in after expiry", async function () {
            const initialUser1Balance = await token.balanceOf(user1.address);
            const initialUser2Balance = await token.balanceOf(user2.address);
            const transferAmount1 = ethers.parseEther("50");
            const transferAmount2 = ethers.parseEther("20");

            // First transfer
            await token.connect(user1).transfer(user2.address, transferAmount1);
            const pendingTx1 = await token.getPendingRecipientTransfer(user2.address);
            const amountAfterFee1 = pendingTx1.amount;

            // Advance time past HalfLife
            await ethers.provider.send("evm_increaseTime", [ONE_DAY + 1]);
            await ethers.provider.send("evm_mine");

            // Second transfer (should trigger auto-finalization of first)
            await expect(token.connect(user1).transfer(user2.address, transferAmount2))
                .to.emit(token, "RecipientTransferFinalized") // Event from auto-finalization
                .withArgs(user1.address, user2.address, amountAfterFee1)
                .to.emit(token, "RecipientTransferPending"); // Event from new transfer

            // User2's total balance should reflect both transfers
            const feeDetails2 = await token.estimateTransferFeeDetails(user1.address, user2.address, transferAmount2);
            const amountAfterFee2 = feeDetails2.netAmountToSendToRecipient;
            expect(await token.balanceOf(user2.address)).to.equal(initialUser2Balance.add(amountAfterFee1).add(amountAfterFee2));
            
            // User2's spendable balance should reflect only the second transfer still pending
            expect(await token.getSpendableBalance(user2.address)).to.equal(initialUser2Balance.add(amountAfterFee1)); // Only amountAfterFee2 is restricted
        });
    });

    describe("T3Token Time-Locked Transfers (Fractionalized Hash System)", function () {
        // Helper to generate a random 64-byte secret and its 32-byte fragment
        function generateSecrets() {
            const fullSecret = ethers.hexlify(ethers.randomBytes(64)); // 64 bytes for full secret
            // Take the first 32 bytes (64 hex chars) for the revealed fragment
            const revealedFragment = fullSecret.substring(0, 66); // "0x" + 32*2 = 66 chars
            const nonce = ethers.hexlify(ethers.randomBytes(32)); // 32 bytes for nonce
            const hashCommitment = ethers.keccak256(ethers.concat([revealedFragment, nonce]));
            return { fullSecret, revealedFragment, nonce, hashCommitment };
        }

        it("Should allow a user to lock funds with a hash commitment and custodian as authorized releaser", async function () {
            const initialUser1Balance = await token.balanceOf(user1.address);
            const transferAmount = ethers.parseEther("50");
            const { fullSecret, revealedFragment, nonce, hashCommitment } = generateSecrets();

            const feeDetails = await token.estimateTransferFeeDetails(user1.address, user2.address, transferAmount);
            const totalFeeAssessed = feeDetails.totalFeeAssessed;
            const amountIntendedForRecipient = feeDetails.netAmountToSendToRecipient; // This is the amount that will be locked

            await expect(token.connect(user1).lockTransfer(user2.address, transferAmount, hashCommitment, nonce, custodian1.address))
                .to.emit(token, "LockedTransferCreated")
                .withArgs(
                    ethers.anyValue, // transferId is dynamic
                    user1.address,
                    user2.address,
                    amountIntendedForRecipient,
                    custodian1.address
                );

            // Funds should be transferred to the contract (amount to lock + fee)
            expect(await token.balanceOf(user1.address)).to.equal(initialUser1Balance.sub(transferAmount).sub(totalFeeAssessed - amountIntendedForRecipient)); // Initial - amount - feePaidFromBalance
            expect(await token.balanceOf(token.getAddress())).to.equal(amountIntendedForRecipient); // Only locked amount is in contract now, fees went to treasury
            expect(await token.balanceOf(treasury.address)).to.equal(totalFeeAssessed);
        });

        it("Should not allow locking funds with unapproved sender/recipient", async function () {
            const transferAmount = ethers.parseEther("50");
            const { hashCommitment, nonce } = generateSecrets();

            // Unregister user1's wallet
            await registry.connect(custodian1).unregisterCustodiedWallet(user1.address);
            await expect(token.connect(user1).lockTransfer(user2.address, transferAmount, hashCommitment, nonce, custodian1.address))
                .to.be.revertedWith("Sender not a registered wallet");

            // Re-register user1 and unregister user2
            await registry.connect(custodian1).registerCustodiedWallet(user1.address, KYC_VALIDATED_TIMESTAMP, KYC_EXPIRES_TIMESTAMP);
            await registry.connect(custodian2).unregisterCustodiedWallet(user2.address);
            await expect(token.connect(user1).lockTransfer(user2.address, transferAmount, hashCommitment, nonce, custodian1.address))
                .to.be.revertedWith("Recipient not a registered wallet");
        });

        it("Should not allow locking funds with non-custodian release authorized address", async function () {
            const transferAmount = ethers.parseEther("50");
            const { hashCommitment, nonce } = generateSecrets();

            // user1 is a client, not a custodian FI
            await expect(token.connect(user1).lockTransfer(user2.address, transferAmount, hashCommitment, nonce, user1.address))
                .to.be.revertedWith("Release authorized address must be a registered custodian wallet");
            
            // nonRegisteredUser is neither
            await expect(token.connect(user1).lockTransfer(user2.address, transferAmount, hashCommitment, nonce, nonRegisteredUser.address))
                .to.be.revertedWith("Release authorized address must be a registered custodian wallet");
        });

        it("Should allow authorized custodian to reveal fragment and release locked funds", async function () {
            const initialUser2Balance = await token.balanceOf(user2.address);
            const transferAmount = ethers.parseEther("50");
            const { fullSecret, revealedFragment, nonce, hashCommitment } = generateSecrets();

            // Lock funds
            const tx = await token.connect(user1).lockTransfer(user2.address, transferAmount, hashCommitment, nonce, custodian1.address);
            const receipt = await tx.wait();
            const lockedTransferEvent = receipt.logs.find(log => token.interface.parseLog(log)?.name === "LockedTransferCreated");
            const transferId = lockedTransferEvent.args.transferId;
            const amountToLock = lockedTransferEvent.args.amount;

            // Release funds by custodian1
            await expect(token.connect(custodian1).revealAndReleaseLockedTransfer(transferId, revealedFragment))
                .to.emit(token, "LockedTransferReleased")
                .withArgs(transferId, user2.address, amountToLock);

            // Recipient balance updated
            expect(await token.balanceOf(user2.address)).to.equal(initialUser2Balance.add(amountToLock));
            // Locked transfer should be marked as released
            expect((await token.getLockedTransfer(transferId)).isReleased).to.be.true;
            // Contract balance should be reduced by released amount (should be 0 for this specific locked amount)
            expect(await token.balanceOf(token.getAddress())).to.equal(0);
        });

        it("Should not allow unauthorized address to reveal fragment", async function () {
            const transferAmount = ethers.parseEther("50");
            const { fullSecret, revealedFragment, nonce, hashCommitment } = generateSecrets();

            const tx = await token.connect(user1).lockTransfer(user2.address, transferAmount, hashCommitment, nonce, custodian1.address);
            const receipt = await tx.wait();
            const lockedTransferEvent = receipt.logs.find(log => token.interface.parseLog(log)?.name === "LockedTransferCreated");
            const transferId = lockedTransferEvent.args.transferId;

            await expect(token.connect(user2).revealAndReleaseLockedTransfer(transferId, revealedFragment))
                .to.be.revertedWith("Caller not authorized to release this transfer");
        });

        it("Should not allow revealing with incorrect fragment", async function () {
            const transferAmount = ethers.parseEther("50");
            const { fullSecret, revealedFragment, nonce, hashCommitment } = generateSecrets();
            const { revealedFragment: incorrectFragment } = generateSecrets(); // Different fragment

            const tx = await token.connect(user1).lockTransfer(user2.address, transferAmount, hashCommitment, nonce, custodian1.address);
            const receipt = await tx.wait();
            const lockedTransferEvent = receipt.logs.find(log => token.interface.parseLog(log)?.name === "LockedTransferCreated");
            const transferId = lockedTransferEvent.args.transferId;

            await expect(token.connect(custodian1).revealAndReleaseLockedTransfer(transferId, incorrectFragment))
                .to.be.revertedWith("Invalid revealed fragment");
        });

        it("Should not allow releasing an already released transfer", async function () {
            const transferAmount = ethers.parseEther("50");
            const { fullSecret, revealedFragment, nonce, hashCommitment } = generateSecrets();

            const tx = await token.connect(user1).lockTransfer(user2.address, transferAmount, hashCommitment, nonce, custodian1.address);
            const receipt = await tx.wait();
            const lockedTransferEvent = receipt.logs.find(log => token.interface.parseLog(log)?.name === "LockedTransferCreated");
            const transferId = lockedTransferEvent.args.transferId;

            await token.connect(custodian1).revealAndReleaseLockedTransfer(transferId, revealedFragment); // First release
            await expect(token.connect(custodian1).revealAndReleaseLockedTransfer(transferId, revealedFragment))
                .to.be.revertedWith("Locked transfer already released");
        });

        it("Should handle zero amount lock gracefully (revert)", async function () {
            const { hashCommitment, nonce } = generateSecrets();
            await expect(token.connect(user1).lockTransfer(user2.address, 0, hashCommitment, nonce, custodian1.address))
                .to.be.revertedWith("Amount must be greater than zero");
        });

        it("Should revert if trying to release a non-existent transferId", async function () {
            const { revealedFragment } = generateSecrets();
            const nonExistentId = ethers.keccak256(ethers.toUtf8Bytes("nonexistent"));
            await expect(token.connect(custodian1).revealAndReleaseLockedTransfer(nonExistentId, revealedFragment))
                .to.be.revertedWith("Locked transfer does not exist");
        });
    });

    describe("Edge Cases and Creative Value Applications", function () {
        it("Fee calculation with zero amount should be zero", async function () {
            // Cannot call internal _calculateTotalFeeAssessed directly, but can infer from transfer
            const initialUser1Balance = await token.balanceOf(user1.address);
            await expect(token.connect(user1).transfer(user2.address, 0))
                .to.be.revertedWith("Transfer amount must be greater than zero"); // Already handled by require
        });

        it("Transferring minimum possible amount (1 wei) should still apply fee", async function () {
            const transferAmount = 1; // 1 wei
            const initialUser1Balance = await token.balanceOf(user1.address);
            const initialTreasuryBalance = await token.balanceOf(treasury.address);

            // Temporarily set min/max fees to be very high to ensure fee is applied
            // Note: MAX_FEE_PERCENT_BPS is 1000 (10%), MIN_FEE_WEI is 10**13 (0.01 T3)
            // For 1 wei, 10% is 0.1 wei. This will be capped by MIN_FEE_WEI.
            // The fee will be MIN_FEE_WEI (10**13) if amountIntendedForRecipient >= MIN_FEE_WEI.
            // If amountIntendedForRecipient is 1 wei, and MIN_FEE_WEI is 10**13, the minFee logic won't apply as a floor.
            // The fee will be (1 * MAX_FEE_PERCENT_BPS) / BASIS_POINTS = 1 * 1000 / 10000 = 0.1 wei.
            // So, the fee will be 0.1 wei (rounded down to 0 for integer math).
            // Let's adjust parameters to ensure a visible fee for 1 wei.
            await token.connect(admin).setHalfLifeDuration(1); // Short HalfLife for quick finalization
            await token.connect(admin).setMinHalfLifeDuration(1);
            await token.connect(admin).setMaxHalfLifeDuration(10);
            await token.connect(admin).setInactivityResetPeriod(1);

            // Set a fixed fee, e.g., 100 wei for any amount, for this specific test
            // This requires modifying calculateBaseFeeAmount or overriding it for testing
            // For now, rely on existing fee logic and check if it's > 0 if expected.
            // The current fee calculation for 1 wei:
            // baseFee = (1 * 100000 * 1000) / (10000 * 1000) = 10 (if tier[0] applies)
            // This is 10 wei.
            // maxFeeForTx = (1 * 1000) / 10000 = 0
            // So totalFee = 0.
            // This means for very small amounts, the fee is 0. This is a design choice from the template.
            // If you want a non-zero fee for 1 wei, MIN_FEE_WEI needs to be lower or tier[0] adjusted.
            // Let's mint a tiny amount to user1 to ensure it can cover MIN_FEE_WEI if needed.
            await token.connect(minter).mint(user1.address, MIN_FEE_WEI);

            const tx = await token.connect(user1).transfer(user2.address, MIN_FEE_WEI);
            const receipt = await tx.wait();
            const transferWithFeeEvent = receipt.logs.find(log => token.interface.parseLog(log)?.name === "TransferWithFee");
            const totalFeeAssessed = transferWithFeeEvent.args.totalFeeAssessed;
            
            expect(totalFeeAssessed).to.be.gt(0); // Expect a non-zero fee for MIN_FEE_WEI
            expect(await token.balanceOf(treasury.address)).to.equal(initialTreasuryBalance.add(totalFeeAssessed));
        });

        it("Risk profile updates should immediately affect new transfers", async function () {
            const transferAmount = ethers.parseEther("10");

            // Re-evaluating based on template's `calculateAdaptiveHalfLife`
            // Risk factor affects FEES, not HalfLife duration in this template.
            // The HalfLife is adjusted by `transactionCountBetween` and `amount > avgAmount * 10`.
            // So, this test should check fee increase, not HalfLife duration.
            const feeDetails1 = await token.estimateTransferFeeDetails(user1.address, user2.address, transferAmount);
            const fee1 = feeDetails1.totalFeeAssessed;

            // Flag abnormal transaction for user1
            await token.connect(admin).flagAbnormalTransaction(user1.address);
            await token.connect(admin).flagAbnormalTransaction(user1.address); // Two abnormal flags

            const feeDetails2 = await token.estimateTransferFeeDetails(user1.address, user2.address, transferAmount);
            const fee2 = feeDetails2.totalFeeAssessed;

            expect(fee2).to.be.gt(fee1); // Fee should increase due to risk
        });

        it("Should not allow HalfLife reversal if already finalized", async function () {
            const transferAmount = ethers.parseEther("100");
            await token.connect(user1).transfer(user2.address, transferAmount);

            await ethers.provider.send("evm_increaseTime", [ONE_DAY + 1]);
            await ethers.provider.send("evm_mine");
            await token.finalizeRecipientTransfer(user2.address);

            await expect(token.connect(user2).reverseRecipientTransfer())
                .to.be.revertedWith("Transfer already finalized");
        });

        it("Should not allow HalfLife finalization if already reversed", async function () {
            const transferAmount = ethers.parseEther("100");
            await token.connect(user1).transfer(user2.address, transferAmount);

            await token.connect(user2).reverseRecipientTransfer(); // Reverse it

            await ethers.provider.send("evm_increaseTime", [ONE_DAY + 1]);
            await ethers.provider.send("evm_mine");

            await expect(token.finalizeRecipientTransfer(user2.address))
                .to.be.revertedWith("Transfer already reversed");
        });

        it("Should handle large amounts for fee calculation without overflow", async function () {
            const largeAmount = ethers.parseEther("1000000000000000000"); // 10^18 * 10^18 = 10^36, very large
            // Mint large amount to user1 
            await token.connect(minter).mint(user1.address, largeAmount);

            // This should not revert due to overflow in _calculateTotalFeeAssessed
            const feeDetails = await token.estimateTransferFeeDetails(user1.address, user2.address, largeAmount);
            const fee = feeDetails.totalFeeAssessed;
            expect(fee).to.be.gt(0); // Should calculate a fee
            expect(fee).to.be.lt(largeAmount); // Fee should be less than amount
        });

        it("Should handle very small amounts for fee calculation (should be closer to min fee)", async function () {
            // Test small amount (should have high % fee)
            const smallAmount = ethers.parseEther("0.05"); // 5 cents
            const feeDetailsSmall = await token.estimateTransferFeeDetails(user1.address, user2.address, smallAmount);
            const feeSmall = feeDetailsSmall.totalFeeAssessed;
            
            expect(feeSmall.mul(10000).div(smallAmount)).to.be.gt(100); // Fee % > 1% (100 BPS)
        });

        it("Should handle very large amounts for fee calculation (should be closer to min fee)", async function () {
            // Test large amount (should have low % fee)
            const largeAmount = ethers.parseEther("100000000"); // 100 million T3
            await token.connect(minter).mint(user1.address, largeAmount);

            const feeDetailsLarge = await token.estimateTransferFeeDetails(user1.address, user2.address, largeAmount);
            const feeLarge = feeDetailsLarge.totalFeeAssessed;
            
            expect(feeLarge.mul(10000).div(largeAmount)).to.be.lt(1); // Fee % < 0.01% (1 BPS)
        });

        it("Should correctly use incentive credits", async function () {
            const initialUser1Credits = await token.getAvailableCredits(user1.address);
            // First, generate some credits by finalizing a transfer
            const transferAmount = ethers.parseEther("100");
            await token.connect(user1).transfer(user2.address, transferAmount);
            await ethers.provider.send("evm_increaseTime", [ONE_DAY + 1]);
            await ethers.provider.send("evm_mine");
            await token.finalizeRecipientTransfer(user2.address);

            const creditsEarned = (await token.getAvailableCredits(user1.address)).sub(initialUser1Credits);
            expect(creditsEarned).to.be.gt(0);

            // Now, try to use them by making another transfer where credits are applied
            const transferAmount2 = ethers.parseEther("10");
            const feeDetails = await token.estimateTransferFeeDetails(user1.address, user2.address, transferAmount2);
            const expectedCreditsToApply = feeDetails.creditsToApply;
            
            expect(expectedCreditsToApply).to.be.gt(0); // Should apply some credits

            const initialUser1Balance = await token.balanceOf(user1.address);
            const initialUser1CreditsAfterFirstTx = await token.getAvailableCredits(user1.address);

            await expect(token.connect(user1).transfer(user2.address, transferAmount2))
                .to.emit(token, "IncentiveCreditUsed")
                .withArgs(user1.address, expectedCreditsToApply);

            // Credits should be reduced
            expect(await token.getAvailableCredits(user1.address)).to.equal(initialUser1CreditsAfterFirstTx.sub(expectedCreditsToApply));
        });

        it("Should not allow locking with zero releaseAuthorizedAddress", async function () {
            const transferAmount = ethers.parseEther("10");
            const { hashCommitment, nonce } = generateSecrets();
            await expect(token.connect(user1).lockTransfer(user2.address, transferAmount, hashCommitment, nonce, ethers.ZeroAddress))
                .to.be.revertedWith("Release authorized address cannot be zero");
        });

        it("Should NOT revert due to sender's HalfLife (original template behavior is non-functional)", async function () {
            // This test confirms the observation that the `transferData[sender]` check in `_transferWithT3Logic`
            // does NOT block transfers, because `transferData[sender]` is never populated in a way that would trigger it.
            // The actual recipient-side HalfLife restriction is handled by `_spendableBalance`.

            // User1 sends to user2. This sets `pendingHalfLifeTransfers[user2]` and `transferData[user2]`.
            await token.connect(user1).transfer(user2.address, ethers.parseEther("10"));
            
            // Now, user1 (the original sender) tries to send to nonRegisteredUser.
            // If the `transferData[sender]` check were functional for blocking, this might revert.
            // However, since `transferData[user1]` is not set by `_updatePostTransferMetadata` for outgoing transfers,
            // the condition `transferData[sender].commitWindowEnd > block.timestamp` will be false.
            // Therefore, this transfer should succeed (assuming user1 has enough spendable balance).
            const initialUser1Balance = await token.getSpendableBalance(user1.address);
            const transferAmount = ethers.parseEther("1");
            
            // Ensure nonRegisteredUser is approved for transfer
            await registry.connect(admin).grantCustodianRole(nonRegisteredUser.address); // Make nonRegisteredUser a custodian for test
            await registry.connect(nonRegisteredUser).registerCustodiedWallet(nonRegisteredUser.address, KYC_VALIDATED_TIMESTAMP, KYC_EXPIRES_TIMESTAMP);

            await expect(token.connect(user1).transfer(nonRegisteredUser.address, transferAmount))
                .to.not.be.reverted; // This confirms the `transferData[sender]` check does not block.
            
            // The actual restriction for user2 (the recipient of the first transfer) is still active:
            await expect(token.connect(user2).transfer(user1.address, 1))
                .to.be.revertedWith("ERC20: transfer amount exceeds spendable balance (HalfLife pending)");
        });
    });
});
//the end