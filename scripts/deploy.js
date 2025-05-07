// scripts/deploy.js
const { ethers } = require("hardhat");
require("dotenv").config(); // Loads variables from .env

async function main() {
  console.log("Starting deployment process...");
  console.log(`Network: ${network.name}`);

  // Get the signers
  const [deployer] = await ethers.getSigners();
  console.log(`Deploying contracts with the account: ${deployer.address}`);

  // Get the initial balance
  const initialBalance = await ethers.provider.getBalance(deployer.address);
  console.log(`Account balance: ${ethers.formatEther(initialBalance)} ETH`);

  let custodianRegistry;
  let t3Token;
  let custodianRegistryAddress;
  let t3TokenAddress;
  let finalBalance;
  let gasUsed;

  try {

    // --- Deploy T3Token ---
    console.log("\n[1/2] Deploying T3Token...");
    const T3Token = await ethers.getContractFactory("T3Token");
    // Using deployer as treasury for this example. Change if needed.
    const treasuryAddress = deployer.address;

    console.log("   --> Preparing deployment transaction for T3Token...");
    // Deploy and get the contract instance
    t3Token = await T3Token.deploy(
      deployer.address, // initialAdmin (or initialOwner)
      treasuryAddress, // treasuryAddress
      {
        gasLimit: 5000000 // Adjusted gas limit (can fine-tune later)
        // Optionally add gas price settings if needed
        //, maxFeePerGas: ethers.parseUnits('50', 'gwei')
        //, maxPriorityFeePerGas: ethers.parseUnits('2', 'gwei')
      }
    );
    console.log("   --> T3Token deployment transaction sent!");

    // Log transaction hash immediately
    const t3DeployTx = t3Token.deploymentTransaction();
     if (!t3DeployTx) {
      console.error("   !!! Could not get deployment transaction for T3Token.");
    } else {
      console.log(`   --> T3Token Tx Hash: ${t3DeployTx.hash}`);
      console.log(`       (Check on Sepolia Etherscan: https://sepolia.etherscan.io/tx/${t3DeployTx.hash})`);
    }

    console.log("   --> Waiting for T3Token deployment transaction to be mined...");
    await t3Token.waitForDeployment();
    t3TokenAddress = await t3Token.getAddress();
    console.log(`✅ T3Token deployed to: ${t3TokenAddress}`);
    // --------------------

	// --- Deploy CustodianRegistry ---
       
	console.log("\n[2/2] Deploying CustodianRegistry...");
    const CustodianRegistry = await ethers.getContractFactory("CustodianRegistry");

    console.log("   --> Preparing deployment transaction for CustodianRegistry...");
    // Deploy and get the contract instance
    custodianRegistry = await CustodianRegistry.deploy(
      deployer.address, // initialAdmin argument
      {
        gasLimit: 1000000 // Increased gas limit (adjust if needed)
        // Optionally add gas price settings like above
        //, maxFeePerGas: ethers.parseUnits('50', 'gwei')
        //, maxPriorityFeePerGas: ethers.parseUnits('2', 'gwei')
      }
    );
    console.log("   --> CustodianRegistry deployment transaction sent!");

    // Log transaction hash immediately
    const custodianDeployTx = custodianRegistry.deploymentTransaction();
    if (!custodianDeployTx) {
      console.error("   !!! Could not get deployment transaction for CustodianRegistry.");
    } else {
      console.log(`   --> CustodianRegistry Tx Hash: ${custodianDeployTx.hash}`);
      console.log(`       (Check on Sepolia Etherscan: https://sepolia.etherscan.io/tx/${custodianDeployTx.hash})`);
    }

    console.log("   --> Waiting for CustodianRegistry deployment transaction to be mined...");
    await custodianRegistry.waitForDeployment(); // Waits for the transaction to be included in a block
    custodianRegistryAddress = await custodianRegistry.getAddress();
    console.log(`✅ CustodianRegistry deployed to: ${custodianRegistryAddress}`);
    
    // ----------------------------------



    // Calculate gas used (approximate)
    finalBalance = await ethers.provider.getBalance(deployer.address);
    gasUsed = initialBalance - finalBalance; // Note: this isn't exact gas cost but balance change
    console.log(`\nApprox. balance change for deployment: ${ethers.formatEther(gasUsed)} ETH`);

    // Log deployment information
    console.log("\nDeployment Summary:");
    console.log("===================");
    console.log(`T3Token: ${t3TokenAddress}`); // Swapped order
    console.log(`CustodianRegistry: ${custodianRegistryAddress}`);
    console.log(`Deployer/Admin: ${deployer.address}`);
    console.log(`Treasury: ${treasuryAddress}`);

    // Reminder to update .env file
    console.log("\n--------------------------------------------------");
    console.log("IMPORTANT: Update your .env file with these addresses:");
    console.log(`T3_TOKEN_ADDRESS=${t3TokenAddress}`); // Swapped order
    console.log(`CUSTODIAN_REGISTRY_ADDRESS=${custodianRegistryAddress}`);
    console.log("--------------------------------------------------");

    return {
      t3TokenAddress, // Swapped order
      custodianRegistryAddress,
      deployerAddress: deployer.address,
      treasuryAddress
    };
  } catch (error) {
    console.error("\n❌ Deployment failed with error:");
    console.error(error);
    throw error; // Re-throw error for non-zero exit code
  }
}

// Execute the deployment
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      // Error is logged in main()
      process.exit(1);
    });
}

module.exports = { main };