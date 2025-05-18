// test/T3System.test.js
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers"); // For fixtures and time manipulation
const { toBigInt } = require("ethers");

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

describe("T3 System: CustodianRegistry and T3Token", function () {
    // We define a fixture to reuse the same setup in every test.
    async function deployT3SystemFixture() {
        const [owner, admin, treasury, custodian1, custodian2, user1, user2, user3, minter, pauser, user4, user5] = await ethers.getSigners();

        // Deploy CustodianRegistry
        const CustodianRegistryFactory = await ethers.getContractFactory("CustodianRegistry");
        const custodianRegistry = await upgrades.deployProxy(
            CustodianRegistryFactory,
            [admin.address], // initialAdmin for CustodianRegistry
            { initializer: "initialize", kind: "uups" }
        );
        await custodianRegistry.waitForDeployment();

        // Define CustodianRegistry Roles
        const ADMIN_ROLE_CR = await custodianRegistry.ADMIN_ROLE();
        const CUSTODIAN_ROLE_CR = await custodianRegistry.CUSTODIAN_ROLE();

        // Deploy T3Token
        const T3TokenFactory = await ethers.getContractFactory("T3Token");
        const oneDayInSeconds = 24 * 60 * 60;
        const initialMintAmount = ethers.parseUnits("10000000", 18); // 10 Million T3Tokens

        const t3Token = await upgrades.deployProxy(
            T3TokenFactory,
            [
                "T3 Stablecoin Test", // name
                "T3T",                // symbol
                admin.address,        // initialAdmin for T3Token
                treasury.address,     // treasuryAddress for T3Token fees
                initialMintAmount,    // initialMintAmount
                3600,                 // initialHalfLifeDuration (1 hour)
                600,                  // initialMinHalfLifeDuration (10 mins)
                oneDayInSeconds,      // initialMaxHalfLifeDuration (1 day)
                30 * oneDayInSeconds  // initialInactivityResetPeriod (30 days)
            ],
            { initializer: "initialize", kind: "uups" }
        );
        await t3Token.waitForDeployment();

        // Define T3Token Roles
        const DEFAULT_ADMIN_ROLE_T3 = await t3Token.DEFAULT_ADMIN_ROLE();
        const ADMIN_ROLE_T3 = await t3Token.ADMIN_ROLE();
        const MINTER_ROLE_T3 = await t3Token.MINTER_ROLE();
        const BURNER_ROLE_T3 = await t3Token.BURNER_ROLE(); 
        const PAUSER_ROLE_T3 = await t3Token.PAUSER_ROLE();

        // Grant necessary roles for testing
        await t3Token.connect(admin).grantRole(MINTER_ROLE_T3, minter.address);
        await t3Token.connect(admin).grantRole(PAUSER_ROLE_T3, pauser.address);
        
        return {
            custodianRegistry, T3TokenFactory, t3Token, CustodianRegistryFactory,
            owner, admin, treasury, custodian1, custodian2, user1, user2, user3, minter, pauser, user4, user5,
            ADMIN_ROLE_CR, CUSTODIAN_ROLE_CR,
            DEFAULT_ADMIN_ROLE_T3, ADMIN_ROLE_T3, MINTER_ROLE_T3, BURNER_ROLE_T3, PAUSER_ROLE_T3,
            initialMintAmount, oneDayInSeconds
        };
    }

    let custodianRegistry, T3TokenFactory, t3Token, CustodianRegistryFactory;
    let owner, admin, treasury, custodian1, custodian2, user1, user2, user3, minter, pauser, user4, user5;
    let ADMIN_ROLE_CR, CUSTODIAN_ROLE_CR;
    let DEFAULT_ADMIN_ROLE_T3, ADMIN_ROLE_T3, MINTER_ROLE_T3, BURNER_ROLE_T3, PAUSER_ROLE_T3;
    let initialMintAmount, oneDayInSeconds;


    beforeEach(async function () {
        const fixtures = await loadFixture(deployT3SystemFixture);
        custodianRegistry = fixtures.custodianRegistry;
        T3TokenFactory = fixtures.T3TokenFactory;
        t3Token = fixtures.t3Token;
        CustodianRegistryFactory = fixtures.CustodianRegistryFactory;
        owner = fixtures.owner;
        admin = fixtures.admin;
        treasury = fixtures.treasury;
        custodian1 = fixtures.custodian1;
        custodian2 = fixtures.custodian2;
        user1 = fixtures.user1;
        user2 = fixtures.user2;
        user3 = fixtures.user3;
        minter = fixtures.minter;
        pauser = fixtures.pauser;
        user4 = fixtures.user4; 
        user5 = fixtures.user5; 
        ADMIN_ROLE_CR = fixtures.ADMIN_ROLE_CR;
        CUSTODIAN_ROLE_CR = fixtures.CUSTODIAN_ROLE_CR;
        DEFAULT_ADMIN_ROLE_T3 = fixtures.DEFAULT_ADMIN_ROLE_T3;
        ADMIN_ROLE_T3 = fixtures.ADMIN_ROLE_T3;
        MINTER_ROLE_T3 = fixtures.MINTER_ROLE_T3;
        BURNER_ROLE_T3 = fixtures.BURNER_ROLE_T3;
        PAUSER_ROLE_T3 = fixtures.PAUSER_ROLE_T3;
        initialMintAmount = fixtures.initialMintAmount;
        oneDayInSeconds = fixtures.oneDayInSeconds;
    });


    describe("CustodianRegistry Deployment and Initialization", function () {
        it("Should set the correct admin roles on CustodianRegistry", async function () {
            expect(await custodianRegistry.hasRole(ADMIN_ROLE_CR, admin.address)).to.be.true;
            expect(await custodianRegistry.hasRole(await custodianRegistry.DEFAULT_ADMIN_ROLE(), admin.address)).to.be.true;
        });

        it("Should allow admin to grant and revoke CUSTODIAN_ROLE", async function () {
            await custodianRegistry.connect(admin).grantCustodianRole(custodian1.address);
            expect(await custodianRegistry.hasRole(CUSTODIAN_ROLE_CR, custodian1.address)).to.be.true;
            expect(await custodianRegistry.custodianCount()).to.equal(ethers.toBigInt(1));
            expect(await custodianRegistry.custodianAtIndex(0)).to.equal(custodian1.address);

            await custodianRegistry.connect(admin).revokeCustodianRole(custodian1.address);
            expect(await custodianRegistry.hasRole(CUSTODIAN_ROLE_CR, custodian1.address)).to.be.false;
            expect(await custodianRegistry.custodianCount()).to.equal(ethers.toBigInt(0));
        });
    });

    describe("CustodianRegistry Functionality", function () {
        beforeEach(async function () {
            await custodianRegistry.connect(admin).grantCustodianRole(custodian1.address);
        });

        it("Should allow a custodian to register and unregister a wallet", async function () {
            const kycValidatedTs = await time.latest() - 3600;
            const kycExpiresTs = kycValidatedTs + (365 * oneDayInSeconds);

            await custodianRegistry.connect(custodian1).registerCustodiedWallet(user1.address, kycValidatedTs, kycExpiresTs);
            expect(await custodianRegistry.getCustodian(user1.address)).to.equal(custodian1.address);
            const [valTs, expTs] = await custodianRegistry.getKYCTimestamps(user1.address);
            expect(valTs).to.equal(ethers.toBigInt(kycValidatedTs));
            expect(expTs).to.equal(ethers.toBigInt(kycExpiresTs));
            expect(await custodianRegistry.isKYCValid(user1.address)).to.be.true;

            await custodianRegistry.connect(custodian1).unregisterCustodiedWallet(user1.address);
            expect(await custodianRegistry.getCustodian(user1.address)).to.equal(ZERO_ADDRESS);
        });

        it("Should allow a custodian to update KYC status", async function () {
            let kycValidatedTs = await time.latest() - (2 * oneDayInSeconds);
            let kycExpiresTs = kycValidatedTs + (10 * oneDayInSeconds);
            await custodianRegistry.connect(custodian1).registerCustodiedWallet(user2.address, kycValidatedTs, kycExpiresTs);

            const newKycValidatedTs = await time.latest();
            const newKycExpiresTs = newKycValidatedTs + (5 * oneDayInSeconds);
            await custodianRegistry.connect(custodian1).updateKYCStatus(user2.address, newKycValidatedTs, newKycExpiresTs);

            const [valTs, expTs] = await custodianRegistry.getKYCTimestamps(user2.address);
            expect(valTs).to.equal(ethers.toBigInt(newKycValidatedTs));
            expect(expTs).to.equal(ethers.toBigInt(newKycExpiresTs));
        });

        it("Should correctly report KYC validity (expired and no expiry)", async function () {
            const validTs = await time.latest() - (5 * oneDayInSeconds);
            const expiredTs = await time.latest() - (1 * oneDayInSeconds);
            await custodianRegistry.connect(custodian1).registerCustodiedWallet(user1.address, validTs, expiredTs);
            expect(await custodianRegistry.isKYCValid(user1.address)).to.be.false;
            await custodianRegistry.connect(custodian1).unregisterCustodiedWallet(user1.address);

            await custodianRegistry.connect(custodian1).registerCustodiedWallet(user2.address, validTs, 0);
            expect(await custodianRegistry.isKYCValid(user2.address)).to.be.true;
        });

        it("Should prevent non-custodians from registering wallets", async function () {
            const kycValidatedTs = await time.latest();
            await expect(
                custodianRegistry.connect(user1).registerCustodiedWallet(user2.address, kycValidatedTs, 0)
            ).to.be.revertedWithCustomError(custodianRegistry, "AccessControlUnauthorizedAccount")
             .withArgs(user1.address, CUSTODIAN_ROLE_CR);
        });

        it("Should prevent updating KYC by a non-registered custodian", async function () {
            await custodianRegistry.connect(custodian1).registerCustodiedWallet(user1.address, await time.latest(), 0);
            await custodianRegistry.connect(admin).grantCustodianRole(custodian2.address);
            await expect(
                custodianRegistry.connect(custodian2).updateKYCStatus(user1.address, await time.latest() + 100, 0)
            ).to.be.revertedWith("Caller is not the registered custodian");
        });
    });

    describe("T3Token Deployment and Initialization", function () {
        it("Should set the correct token name and symbol", async function () {
            expect(await t3Token.name()).to.equal("T3 Stablecoin Test");
            expect(await t3Token.symbol()).to.equal("T3T");
        });

        it("Should set the correct admin and pauser roles on T3Token", async function () {
            expect(await t3Token.hasRole(ADMIN_ROLE_T3, admin.address)).to.be.true;
            expect(await t3Token.hasRole(DEFAULT_ADMIN_ROLE_T3, admin.address)).to.be.true;
            expect(await t3Token.hasRole(PAUSER_ROLE_T3, admin.address)).to.be.true;
            expect(await t3Token.hasRole(PAUSER_ROLE_T3, pauser.address)).to.be.true;
        });

        it("Should set the treasury address", async function () {
            expect(await t3Token.treasuryAddress()).to.equal(treasury.address);
        });

        it("Should mint initial supply to the admin (or specified recipient)", async function () {
            expect(await t3Token.balanceOf(admin.address)).to.equal(initialMintAmount);
        });

        it("Should set HalfLife parameters correctly", async function () {
            expect(await t3Token.halfLifeDuration()).to.equal(ethers.toBigInt(3600));
            expect(await t3Token.minHalfLifeDuration()).to.equal(ethers.toBigInt(600));
            expect(await t3Token.maxHalfLifeDuration()).to.equal(ethers.toBigInt(oneDayInSeconds));
            expect(await t3Token.inactivityResetPeriod()).to.equal(ethers.toBigInt(30 * oneDayInSeconds));
        });
    });

    describe("T3Token Core Functionality", function () {
        const baseTransferAmount = ethers.parseUnits("100", 18);
        const feeBuffer = ethers.parseUnits("1", 18); // Buffer for fees in setup

        beforeEach(async function () {
            const requiredAdminBalance = baseTransferAmount * ethers.toBigInt(5); // Initial funding for admin
            const currentAdminBalance = await t3Token.balanceOf(admin.address);
            if (currentAdminBalance < requiredAdminBalance) {
                await t3Token.connect(minter).mint(admin.address, requiredAdminBalance - currentAdminBalance);
            }

            // Admin transfers to user1
            await t3Token.connect(admin).transfer(user1.address, baseTransferAmount);
            let transferDataUser1 = await t3Token.transferData(user1.address);
            let currentBlockTimestamp = await time.latest();
            if (transferDataUser1.commitWindowEnd > currentBlockTimestamp) {
                await time.increaseTo(transferDataUser1.commitWindowEnd + BigInt(1));
            }

            // User1 transfers to user2
            const smallTransfer = ethers.parseUnits("1", 18);
            let currentUser1Balance = await t3Token.balanceOf(user1.address);
            // Estimate fee for user1's transfer to user2
            const feeEst1 = await t3Token.estimateTransferFeeDetails(user1.address, user2.address, smallTransfer);
            const totalCost1 = smallTransfer + feeEst1.totalFeeAssessed;
            if (currentUser1Balance < totalCost1) { 
                 await t3Token.connect(minter).mint(user1.address, totalCost1 - currentUser1Balance + feeBuffer); 
            }
            await t3Token.connect(user1).transfer(user2.address, smallTransfer);
            let transferDataUser2 = await t3Token.transferData(user2.address);
            currentBlockTimestamp = await time.latest();
            if (transferDataUser2.commitWindowEnd > currentBlockTimestamp) {
                await time.increaseTo(transferDataUser2.commitWindowEnd + BigInt(1));
            }
            
            // User2 transfers back to user1
            let currentUser2Balance = await t3Token.balanceOf(user2.address);
            const feeEst2 = await t3Token.estimateTransferFeeDetails(user2.address, user1.address, smallTransfer);
            const totalCost2 = smallTransfer + feeEst2.totalFeeAssessed;
            if (currentUser2Balance < totalCost2) { 
                 await t3Token.connect(minter).mint(user2.address, totalCost2 - currentUser2Balance + feeBuffer);
            }
            await t3Token.connect(user2).transfer(user1.address, smallTransfer);
            transferDataUser1 = await t3Token.transferData(user1.address); // user1 is recipient
            currentBlockTimestamp = await time.latest();
            if (transferDataUser1.commitWindowEnd > currentBlockTimestamp) {
                await time.increaseTo(transferDataUser1.commitWindowEnd + BigInt(1));
            }
        });

        it("Should allow admin to set treasury address", async function () {
            await t3Token.connect(admin).setTreasuryAddress(user2.address);
            expect(await t3Token.treasuryAddress()).to.equal(user2.address);
        });

        it("Should allow admin to set HalfLife parameters", async function () {
            await t3Token.connect(admin).setHalfLifeDuration(1800);
            expect(await t3Token.halfLifeDuration()).to.equal(ethers.toBigInt(1800));
        });

        it("Should allow a minter to mint tokens", async function () {
            const mintAmount = ethers.parseUnits("500", 18);
            const balBefore = await t3Token.balanceOf(user1.address);
            await t3Token.connect(minter).mint(user1.address, mintAmount);
            expect(await t3Token.balanceOf(user1.address)).to.equal(balBefore + mintAmount);
        });

        it("Should allow transfers with fee deduction (paid from balance)", async function () {
            const amountIntendedForRecipient = ethers.parseUnits("50", 18);
            
            const estimatedFeeDetails = await t3Token.estimateTransferFeeDetails(user1.address, user2.address, amountIntendedForRecipient);
            const totalFeeAssessedEst = estimatedFeeDetails.totalFeeAssessed;
            const totalCostToSenderEst = amountIntendedForRecipient + totalFeeAssessedEst;

            let user1CurrentBalance = await t3Token.balanceOf(user1.address);
            if (user1CurrentBalance < totalCostToSenderEst) {
                 await t3Token.connect(minter).mint(user1.address, totalCostToSenderEst - user1CurrentBalance + ethers.parseUnits("1",18)); 
            }
        
            const initialUser1Balance = await t3Token.balanceOf(user1.address);
            const initialUser2Balance = await t3Token.balanceOf(user2.address);
            const initialTreasuryBalance = await t3Token.balanceOf(treasury.address);
            const initialSenderCredits = await t3Token.getAvailableCredits(user1.address);
            const initialRecipientCredits = await t3Token.getAvailableCredits(user2.address);
            const initialSenderPrefund = await t3Token.getPrefundedFeeBalance(user1.address);
        
            const txResponse = await t3Token.connect(user1).transfer(user2.address, amountIntendedForRecipient);
            const txReceipt = await txResponse.wait();
            
            let actualTotalFeeAssessed = ethers.toBigInt(0);
            let actualFeePaidFromBalance = ethers.toBigInt(0);
            let actualFeePaidFromPrefund = ethers.toBigInt(0);
            let actualFeePaidFromCredits = ethers.toBigInt(0);

            const transferWithFeeEvent = txReceipt.logs.find(log => {
                try { const parsed = t3Token.interface.parseLog(log); return parsed && parsed.name === "TransferWithFee"; } catch(e){ return false; }
            });
            if (transferWithFeeEvent) { 
                const parsedArgs = t3Token.interface.parseLog(transferWithFeeEvent).args;
                actualTotalFeeAssessed = parsedArgs.totalFeeAssessed;
                actualFeePaidFromBalance = parsedArgs.feePaidFromBalance;
                actualFeePaidFromPrefund = parsedArgs.feePaidFromPrefund;
                actualFeePaidFromCredits = parsedArgs.feePaidFromCredits;
            }
        
            expect(await t3Token.balanceOf(user1.address)).to.equal(initialUser1Balance - amountIntendedForRecipient - actualFeePaidFromBalance);
            expect(await t3Token.balanceOf(user2.address)).to.equal(initialUser2Balance + amountIntendedForRecipient);
            expect(await t3Token.balanceOf(treasury.address)).to.equal(initialTreasuryBalance + actualFeePaidFromBalance + actualFeePaidFromPrefund); 
        
            const expectedSenderShare = actualTotalFeeAssessed / ethers.toBigInt(4);
            const expectedRecipientShare = actualTotalFeeAssessed / ethers.toBigInt(4);

            expect(await t3Token.getAvailableCredits(user1.address)).to.equal(initialSenderCredits - actualFeePaidFromCredits + expectedSenderShare);
            expect(await t3Token.getAvailableCredits(user2.address)).to.equal(initialRecipientCredits + expectedRecipientShare);
            expect(await t3Token.getPrefundedFeeBalance(user1.address)).to.equal(initialSenderPrefund - actualFeePaidFromPrefund);
        });


        it("Should respect HalfLife: prevent transfer during commit window to other than originator", async function () {
            const specificTransferAmount = ethers.parseUnits("30", 18);
            let user1Bal = await t3Token.balanceOf(user1.address);
            const feeDetails = await t3Token.estimateTransferFeeDetails(user1.address, user3.address, specificTransferAmount);
            const totalCost = specificTransferAmount + feeDetails.totalFeeAssessed;
            if (user1Bal < totalCost) {
                await t3Token.connect(minter).mint(user1.address, totalCost - user1Bal + ethers.parseUnits("1",18));
            }
            let transferDataUser1 = await t3Token.transferData(user1.address);
            let currentBlockTimestamp = await time.latest();
            if (transferDataUser1.commitWindowEnd > currentBlockTimestamp) {
                await time.increaseTo(transferDataUser1.commitWindowEnd + BigInt(1));
            }

            await t3Token.connect(user1).transfer(user3.address, specificTransferAmount);

            await expect(
                t3Token.connect(user3).transfer(user2.address, ethers.parseUnits("10", 18))
            ).to.be.revertedWith("Cannot transfer during HalfLife period except back to originator");

            await expect(
                t3Token.connect(user3).transfer(user1.address, ethers.parseUnits("10", 18))
            ).to.not.be.reverted;
        });

        it("Should allow reversal within HalfLife window by originator", async function () {
            const amountIntendedForRecipient = ethers.parseUnits("40", 18);
            let user1BalRev = await t3Token.balanceOf(user1.address);
            const feeDetailsForTransfer = await t3Token.estimateTransferFeeDetails(user1.address, user2.address, amountIntendedForRecipient);
            const totalCostForTransfer = amountIntendedForRecipient + feeDetailsForTransfer.totalFeeAssessed;

            if (user1BalRev < totalCostForTransfer) {
                await t3Token.connect(minter).mint(user1.address, totalCostForTransfer - user1BalRev + ethers.parseUnits("1",18));
            }
            let transferDataUser1_rev = await t3Token.transferData(user1.address);
            let currentBlockTimestamp_rev = await time.latest();
            if (transferDataUser1_rev.commitWindowEnd > currentBlockTimestamp_rev) {
                await time.increaseTo(transferDataUser1_rev.commitWindowEnd + BigInt(1));
            }

            const u1BalanceBeforeTransfer = await t3Token.balanceOf(user1.address);
            const u2BalanceBeforeTransfer = await t3Token.balanceOf(user2.address);

            const tx = await t3Token.connect(user1).transfer(user2.address, amountIntendedForRecipient);
            await tx.wait();
            
            const u1BalanceAfterTransfer = await t3Token.balanceOf(user1.address);
            const u2BalanceAfterTransfer = await t3Token.balanceOf(user2.address);
            
            expect(u2BalanceAfterTransfer).to.equal(u2BalanceBeforeTransfer + amountIntendedForRecipient);

            await t3Token.connect(user1).reverseTransfer(user2.address, amountIntendedForRecipient);

            expect(await t3Token.balanceOf(user1.address)).to.equal(u1BalanceAfterTransfer + amountIntendedForRecipient);
            expect(await t3Token.balanceOf(user2.address)).to.equal(u2BalanceBeforeTransfer);

            const tdUser2 = await t3Token.transferData(user2.address);
            expect(tdUser2.isReversed).to.be.true;
        });


        it("Should process HalfLife expiry and distribute loyalty credits", async function () {
            const expiryTestAmount = ethers.parseUnits("60", 18);
            let user1BalExp = await t3Token.balanceOf(user1.address);
            const feeDetailsExp = await t3Token.estimateTransferFeeDetails(user1.address, user2.address, expiryTestAmount);
            const totalCostExp = expiryTestAmount + feeDetailsExp.totalFeeAssessed;
             if (user1BalExp < totalCostExp) {
                await t3Token.connect(minter).mint(user1.address, totalCostExp - user1BalExp + ethers.parseUnits("1",18));
            }
            let transferDataUser1_exp = await t3Token.transferData(user1.address);
            let currentBlockTimestamp_exp = await time.latest();
            if (transferDataUser1_exp.commitWindowEnd > currentBlockTimestamp_exp) {
                await time.increaseTo(transferDataUser1_exp.commitWindowEnd + BigInt(1));
            }

            await t3Token.connect(user1).transfer(user2.address, expiryTestAmount);
            const transferMeta = await t3Token.transferData(user2.address); 
            
            const currentTimestamp = await time.latest();
            if (transferMeta.commitWindowEnd > currentTimestamp) {
                 await time.increaseTo(transferMeta.commitWindowEnd + BigInt(1));
            } else {
                await time.increase(BigInt(1)); 
            }

            const initialCreditsUser1 = await t3Token.getAvailableCredits(user1.address);
            const initialCreditsUser2 = await t3Token.getAvailableCredits(user2.address);

            await t3Token.checkHalfLifeExpiry(user2.address);

            const finalCreditsUser1 = await t3Token.getAvailableCredits(user1.address);
            const finalCreditsUser2 = await t3Token.getAvailableCredits(user2.address);

            if (transferMeta.totalFeeAssessed > 0) {
                const expectedRefundBase = transferMeta.totalFeeAssessed / ethers.toBigInt(8);
                const expectedRefundPerParty = expectedRefundBase / ethers.toBigInt(2);
                if (expectedRefundPerParty > 0) {
                    expect(finalCreditsUser1).to.equal(initialCreditsUser1 + expectedRefundPerParty);
                    expect(finalCreditsUser2).to.equal(initialCreditsUser2 + expectedRefundPerParty);
                } else { 
                    expect(finalCreditsUser1).to.equal(initialCreditsUser1);
                    expect(finalCreditsUser2).to.equal(initialCreditsUser2);
                }
            } else { 
                 expect(finalCreditsUser1).to.equal(initialCreditsUser1);
                 expect(finalCreditsUser2).to.equal(initialCreditsUser2);
            }
            const tdUser2AfterExpiry = await t3Token.transferData(user2.address);
            expect(tdUser2AfterExpiry.commitWindowEnd).to.equal(ethers.toBigInt(0));
        });


        it("Should allow pauser to pause and unpause transfers", async function () {
            await t3Token.connect(pauser).pause();
            await expect(
                t3Token.connect(user1).transfer(user2.address, baseTransferAmount)
            ).to.be.revertedWithCustomError(t3Token, "EnforcedPause");

            await t3Token.connect(pauser).unpause();
            
            let transferDataUser1 = await t3Token.transferData(user1.address);
            let currentBlockTimestamp = await time.latest();
            if (transferDataUser1.commitWindowEnd > currentBlockTimestamp && 
                transferDataUser1.originator !== user2.address && 
                transferDataUser1.originator !== ZERO_ADDRESS) { 
                 await time.increaseTo(transferDataUser1.commitWindowEnd + BigInt(1));
            }
             
            const user1Bal = await t3Token.balanceOf(user1.address);
            const feeDetailsUnpause = await t3Token.estimateTransferFeeDetails(user1.address, user2.address, baseTransferAmount);
            const totalCostUnpause = baseTransferAmount + feeDetailsUnpause.totalFeeAssessed;
            if (user1Bal < totalCostUnpause) {
                await t3Token.connect(minter).mint(user1.address, totalCostUnpause - user1Bal + ethers.parseUnits("1",18));
            }

            await expect(
                t3Token.connect(user1).transfer(user2.address, baseTransferAmount)
            ).to.not.be.reverted;
        });

         it("Should allow burning of tokens by owner of tokens", async function () {
            const burnAmount = ethers.parseUnits("10", 18);
            let user1BalBurn = await t3Token.balanceOf(user1.address);
            if (user1BalBurn < burnAmount) {
                await t3Token.connect(minter).mint(user1.address, burnAmount);
            }
            const balanceBeforeBurn = await t3Token.balanceOf(user1.address);
            await t3Token.connect(user1).burn(burnAmount);
            expect(await t3Token.balanceOf(user1.address)).to.equal(balanceBeforeBurn - burnAmount);
        });

        it("Should allow burning of tokens via burnFrom after approval", async function () {
            const burnAmount = ethers.parseUnits("10", 18);
            let user1BalBurnFrom = await t3Token.balanceOf(user1.address);
            if (user1BalBurnFrom < burnAmount) {
                 await t3Token.connect(minter).mint(user1.address, burnAmount);
            }
            const balanceBeforeBurn = await t3Token.balanceOf(user1.address);

            await t3Token.connect(user1).approve(admin.address, burnAmount);
            await t3Token.connect(admin).burnFrom(user1.address, burnAmount);
            expect(await t3Token.balanceOf(user1.address)).to.equal(balanceBeforeBurn - burnAmount);
        });
    });

    describe("T3Token Transfer Functionality (Extended with Pre-funding)", function() {
        const smallAmount = ethers.parseUnits("5", 18);
        const mediumAmount = ethers.parseUnits("50", 18);
        const largeAmount = ethers.parseUnits("5000", 18);
        let initialUser1Balance_ext, initialUser2Balance_ext, initialTreasuryBalance_ext, initialUser1Prefund_ext, initialUser1Credits_ext; // Suffix to avoid clash


        beforeEach(async function() {
            await t3Token.connect(minter).mint(user1.address, ethers.parseUnits("20000", 18));
            await t3Token.connect(minter).mint(user2.address, ethers.parseUnits("10000", 18));
            await t3Token.connect(minter).mint(user4.address, ethers.parseUnits("10000", 18));
            await t3Token.connect(minter).mint(user5.address, ethers.parseUnits("10000", 18));

            const latestBlockTime = await time.latest();
            await time.increaseTo(latestBlockTime + oneDayInSeconds * 3); 

            const ensureProfileAndClearWindow = async (user, recipient) => {
                const smallTx = ethers.parseUnits("0.00001", 18);
                const feeEstEnsure = await t3Token.estimateTransferFeeDetails(user.address, recipient.address, smallTx);
                const costEnsure = smallTx + feeEstEnsure.totalFeeAssessed;

                if ((await t3Token.walletRiskProfiles(user.address)).creationTime == 0) {
                    if (await t3Token.balanceOf(user.address) < costEnsure) await t3Token.connect(minter).mint(user.address, costEnsure);
                    await t3Token.connect(user).transfer(recipient.address, smallTx);
                }
                let transferData = await t3Token.transferData(recipient.address); 
                let currentTs = await time.latest();
                if (transferData.commitWindowEnd > currentTs) {
                    await time.increaseTo(transferData.commitWindowEnd + BigInt(1));
                }
                transferData = await t3Token.transferData(user.address); 
                currentTs = await time.latest();
                 if (transferData.commitWindowEnd > currentTs) {
                    await time.increaseTo(transferData.commitWindowEnd + BigInt(1));
                }
            };

            await ensureProfileAndClearWindow(user1, user2);
            await ensureProfileAndClearWindow(user2, user1);
            await ensureProfileAndClearWindow(user4, user5);
            await ensureProfileAndClearWindow(user5, user4);
            
            initialUser1Balance_ext = await t3Token.balanceOf(user1.address);
            initialUser2Balance_ext = await t3Token.balanceOf(user2.address);
            initialTreasuryBalance_ext = await t3Token.balanceOf(treasury.address);
            initialUser1Prefund_ext = await t3Token.getPrefundedFeeBalance(user1.address);
            initialUser1Credits_ext = await t3Token.getAvailableCredits(user1.address);
        });

        it("Should allow a user to pre-fund fees", async function() {
            const prefundAmount = ethers.parseUnits("10", 18);
            const user1BalBefore = await t3Token.balanceOf(user1.address);
            const treasuryBalBefore = await t3Token.balanceOf(treasury.address);
            const prefundBalBefore = await t3Token.getPrefundedFeeBalance(user1.address);

            await expect(t3Token.connect(user1).prefundFees(prefundAmount))
                .to.emit(t3Token, "FeePrefunded")
                .withArgs(user1.address, prefundAmount);

            expect(await t3Token.balanceOf(user1.address)).to.equal(user1BalBefore - prefundAmount);
            expect(await t3Token.balanceOf(treasury.address)).to.equal(treasuryBalBefore + prefundAmount);
            expect(await t3Token.getPrefundedFeeBalance(user1.address)).to.equal(prefundBalBefore + prefundAmount);
        });

        it("Should allow a user to withdraw pre-funded fees", async function() {
            const prefundAmount = ethers.parseUnits("10", 18);
            await t3Token.connect(user1).prefundFees(prefundAmount); 

            const user1BalBeforeWithdraw = await t3Token.balanceOf(user1.address);
            const treasuryBalBeforeWithdraw = await t3Token.balanceOf(treasury.address);
            const prefundBalBeforeWithdraw = await t3Token.getPrefundedFeeBalance(user1.address);

            await expect(t3Token.connect(user1).withdrawPrefundedFees(prefundAmount))
                .to.emit(t3Token, "PrefundedFeeWithdrawn")
                .withArgs(user1.address, prefundAmount);

            expect(await t3Token.balanceOf(user1.address)).to.equal(user1BalBeforeWithdraw + prefundAmount);
            expect(await t3Token.balanceOf(treasury.address)).to.equal(treasuryBalBeforeWithdraw - prefundAmount);
            expect(await t3Token.getPrefundedFeeBalance(user1.address)).to.equal(prefundBalBeforeWithdraw - prefundAmount);
        });

        it("Should revert if withdrawing more pre-funded fees than available", async function() {
            await expect(t3Token.connect(user1).withdrawPrefundedFees(ethers.parseUnits("1", 18)))
                .to.be.revertedWith("Insufficient pre-funded balance");
        });


        it("Transfer: Fee fully covered by pre-funded amount", async function() {
            const amountToSend = mediumAmount;
            const estimatedDetails = await t3Token.estimateTransferFeeDetails(user1.address, user2.address, amountToSend);
            const feeToCoverByPrefund = estimatedDetails.totalFeeAssessed;

            if (feeToCoverByPrefund > ethers.toBigInt(0)) {
                if (await t3Token.balanceOf(user1.address) < feeToCoverByPrefund) { 
                    await t3Token.connect(minter).mint(user1.address, feeToCoverByPrefund);
                }
                await t3Token.connect(user1).prefundFees(feeToCoverByPrefund); 
            } else {
                 console.warn("Skipping 'fee fully covered by prefund' as estimated fee is 0");
                 return; 
            }
            
            const u1Bal = await t3Token.balanceOf(user1.address);
            const u2Bal = await t3Token.balanceOf(user2.address);
            const treasBal = await t3Token.balanceOf(treasury.address); 
            const u1Prefund = await t3Token.getPrefundedFeeBalance(user1.address);

            const tx = await t3Token.connect(user1).transfer(user2.address, amountToSend);
            
            await expect(tx)
                .to.emit(t3Token, "TransferWithFee")
                .withArgs(user1.address, user2.address, amountToSend, feeToCoverByPrefund, 0, feeToCoverByPrefund, 0); 
            await expect(tx).to.emit(t3Token, "PrefundedFeeUsed").withArgs(user1.address, feeToCoverByPrefund);

            expect(await t3Token.balanceOf(user1.address)).to.equal(u1Bal - amountToSend); 
            expect(await t3Token.balanceOf(user2.address)).to.equal(u2Bal + amountToSend);
            expect(await t3Token.getPrefundedFeeBalance(user1.address)).to.equal(u1Prefund - feeToCoverByPrefund);
            expect(await t3Token.balanceOf(treasury.address)).to.equal(treasBal); 
        });

        it("Transfer: Fee partially by pre-fund, then by credits, then by balance", async function() {
            const amountToSend = mediumAmount;
            const estimatedDetails = await t3Token.estimateTransferFeeDetails(user1.address, user2.address, amountToSend);
            const totalFeeAssessedForTx = estimatedDetails.totalFeeAssessed;

            if (totalFeeAssessedForTx === ethers.toBigInt(0)) {
                console.warn("Skipping 'fee partially by pre-fund, credits, balance' as estimated fee is 0");
                return;
            }

            const prefundPart = totalFeeAssessedForTx / ethers.toBigInt(3);
            
            const setupTransferAmount = ethers.parseUnits("300", 18); 
            const feeEstSetup = await t3Token.estimateTransferFeeDetails(user4.address, user1.address, setupTransferAmount);
            const costSetup = setupTransferAmount + feeEstSetup.totalFeeAssessed;
            if (await t3Token.balanceOf(user4.address) < costSetup) {
                await t3Token.connect(minter).mint(user4.address, costSetup);
            }
            await t3Token.connect(user4).transfer(user1.address, setupTransferAmount); 
            //had to use let bc needs to be updated after transfer
            let currentTime = await time.latest() + 250;
            currentTime = toBigInt(currentTime);
            //console.log(`Current Time: ${currentTime} ${typeof currentTime}`);
            const halfLifeDuration = await t3Token.halfLifeDuration();
            //console.log(`Half Life Duration: ${halfLifeDuration} ${typeof halfLifeDuration}`);
            //console.log(`Target Time: ${currentTime + halfLifeDuration}`);
            const targetTime = currentTime + halfLifeDuration;
            await time.increaseTo(targetTime);


            if (prefundPart > 0) {
                if (await t3Token.balanceOf(user1.address) < prefundPart) await t3Token.connect(minter).mint(user1.address, prefundPart);
                await t3Token.connect(user1).prefundFees(prefundPart);
            }

            const u1Bal = await t3Token.balanceOf(user1.address);
            const u2Bal = await t3Token.balanceOf(user2.address);
            const treasBal = await t3Token.balanceOf(treasury.address);
            const u1PrefundInitial = await t3Token.getPrefundedFeeBalance(user1.address);
            const u1CreditsInitial = await t3Token.getAvailableCredits(user1.address);

            const tx = await t3Token.connect(user1).transfer(user2.address, amountToSend);
            const receipt = await tx.wait();

            let feePaidFromBalanceActual = ethers.toBigInt(0);
            let feePaidFromPrefundActual = ethers.toBigInt(0);
            let feePaidFromCreditsActual = ethers.toBigInt(0);
            let actualTotalFeeInEvent = ethers.toBigInt(0);

            const transferWithFeeEventLog = receipt.logs.find(log => {
                try { const parsed = t3Token.interface.parseLog(log); return parsed && parsed.name === "TransferWithFee"; } catch(e){ return false; }
            });
            if (transferWithFeeEventLog) {
                const args = t3Token.interface.parseLog(transferWithFeeEventLog).args;
                actualTotalFeeInEvent = args.totalFeeAssessed; 
                feePaidFromBalanceActual = args.feePaidFromBalance;
                feePaidFromPrefundActual = args.feePaidFromPrefund;
                feePaidFromCreditsActual = args.feePaidFromCredits;
            }
            
            expect(await t3Token.balanceOf(user1.address)).to.equal(u1Bal - amountToSend - feePaidFromBalanceActual);
            expect(await t3Token.balanceOf(user2.address)).to.equal(u2Bal + amountToSend);
            expect(await t3Token.balanceOf(treasury.address)).to.equal(treasBal + feePaidFromBalanceActual); 
            expect(await t3Token.getPrefundedFeeBalance(user1.address)).to.equal(u1PrefundInitial - feePaidFromPrefundActual);
            
            const earnedSenderCredits = BigInt(actualTotalFeeInEvent.toString()) / BigInt(4); // Ensure BigInt division
            const expectedFinalCredits = (BigInt(u1CreditsInitial.toString()) - BigInt(feePaidFromCreditsActual.toString())) + BigInt(earnedSenderCredits);

            // Logging for the failing test
            /*  
            console.log(`--- Failing Test Debug ---`);
            console.log(`User1 Credits Initial (u1CreditsInitial): ${u1CreditsInitial.toString()} (Type: ${typeof u1CreditsInitial})`);
            console.log(`Fee Paid From Credits Actual (feePaidFromCreditsActual): ${feePaidFromCreditsActual.toString()} (Type: ${typeof feePaidFromCreditsActual})`);
            console.log(`Actual Total Fee In Event (actualTotalFeeInEvent): ${actualTotalFeeInEvent.toString()} (Type: ${typeof actualTotalFeeInEvent})`);
            console.log(`Earned Sender Credits (earnedSenderCredits): ${earnedSenderCredits.toString()} (Type: ${typeof earnedSenderCredits})`);
            console.log(`Expected Final Credits (calculated): ${expectedFinalCredits.toString()} (Type: ${typeof expectedFinalCredits})`); 
            */
            const actualFinalUser1Credits = await t3Token.getAvailableCredits(user1.address);
            //console.log(`Actual Final User1 Credits (from contract): ${actualFinalUser1Credits.toString()} (Type: ${typeof actualFinalUser1Credits})`);


            expect(actualFinalUser1Credits).to.equal(expectedFinalCredits);
        });


        it("Should fail to transfer if total cost (amount + fee_from_balance) exceeds balance, even with some prefund/credits", async function() {
            const user1InitialBal = await t3Token.balanceOf(user1.address);
            const amountToSend = user1InitialBal + ethers.parseUnits("1000", 18); 
            
            const prefundAmount = ethers.parseUnits("1", 18); 
            if (user1InitialBal >= prefundAmount) { 
                 await t3Token.connect(user1).prefundFees(prefundAmount);
            } else { 
                if (user1InitialBal > 0) await t3Token.connect(user1).prefundFees(user1InitialBal); 
            }
            
            await expect(t3Token.connect(user1).transfer(user2.address, amountToSend))
                .to.be.revertedWithCustomError(t3Token, "ERC20InsufficientBalance");
        });


        it("Should fail to transfer zero amount", async function() {
            await expect(t3Token.connect(user1).transfer(user2.address, 0))
                .to.be.revertedWith("Transfer amount must be greater than zero");
        });

        it("Should fail to transfer to the zero address", async function() {
            await expect(t3Token.connect(user1).transfer(ZERO_ADDRESS, mediumAmount))
                .to.be.revertedWith("Transfer to zero address");
        });

        it("Should fail to transfer more than balance (considering fee from balance)", async function() {
            const balance = await t3Token.balanceOf(user1.address);
            const amountToSend = balance; 
            
            const feeDetails = await t3Token.estimateTransferFeeDetails(user1.address, user2.address, amountToSend);
            const prefunded = await t3Token.getPrefundedFeeBalance(user1.address);
            const credits = await t3Token.getAvailableCredits(user1.address);
            
            let feePayableFromBalance = feeDetails.totalFeeAssessed;
            if (feePayableFromBalance > prefunded) {
                feePayableFromBalance -= prefunded;
            } else {
                feePayableFromBalance = ethers.toBigInt(0);
            }
            if (feePayableFromBalance > credits) {
                feePayableFromBalance -= credits;
            } else {
                feePayableFromBalance = ethers.toBigInt(0);
            }

            if (feePayableFromBalance > 0) { 
                 await expect(t3Token.connect(user1).transfer(user2.address, amountToSend))
                    .to.be.revertedWithCustomError(t3Token, "ERC20InsufficientBalance");
            } else {
                await expect(t3Token.connect(user1).transfer(user2.address, amountToSend)).to.not.be.reverted;
                expect(await t3Token.balanceOf(user1.address)).to.equal(0);
            }
        });
    });


    describe("T3Token Upgradeability (UUPS)", function () {
        it("Admin should be able to upgrade the T3Token contract", async function () {
            const T3TokenV2Factory = await ethers.getContractFactory("T3Token", admin);
            const currentImplementationAddress = await upgrades.erc1967.getImplementationAddress(await t3Token.getAddress());
            
            const upgradedT3Token = await upgrades.upgradeProxy(await t3Token.getAddress(), T3TokenV2Factory);
            await upgradedT3Token.waitForDeployment();
            const newImplementationAddress = await upgrades.erc1967.getImplementationAddress(await upgradedT3Token.getAddress());

            expect(await upgradedT3Token.getAddress()).to.equal(await t3Token.getAddress());
            if (T3TokenV2Factory.bytecode !== T3TokenFactory.bytecode) { 
                 expect(newImplementationAddress).to.not.equal(currentImplementationAddress);
            }
            expect(await upgradedT3Token.name()).to.equal("T3 Stablecoin Test");
        });

        it("Non-admin should not be able to upgrade the T3Token contract", async function () {
            const T3TokenV2Factory_NotAdmin = await ethers.getContractFactory("T3Token", user1);
            await expect(
                 upgrades.upgradeProxy(await t3Token.getAddress(), T3TokenV2Factory_NotAdmin)
            ).to.be.revertedWithCustomError(t3Token, "AccessControlUnauthorizedAccount")
             .withArgs(user1.address, ADMIN_ROLE_T3);
        });

         it("Admin should be able to upgrade the CustodianRegistry contract", async function () {
            const CustodianRegistryV2Factory = await ethers.getContractFactory("CustodianRegistry", admin);
            const currentCRImplementation = await upgrades.erc1967.getImplementationAddress(await custodianRegistry.getAddress());
            
            const upgradedCR = await upgrades.upgradeProxy(await custodianRegistry.getAddress(), CustodianRegistryV2Factory);
            await upgradedCR.waitForDeployment();
            const newCRImplementation = await upgrades.erc1967.getImplementationAddress(await upgradedCR.getAddress());

            expect(await upgradedCR.getAddress()).to.equal(await custodianRegistry.getAddress());
            if (CustodianRegistryV2Factory.bytecode !== CustodianRegistryFactory.bytecode) {
                expect(newCRImplementation).to.not.equal(currentCRImplementation);
            }
            expect(await upgradedCR.hasRole(ADMIN_ROLE_CR, admin.address)).to.be.true;
        });
    });
});
