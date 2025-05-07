// scripts/deploy_t3_only_hardcoded.js
// Deploys ONLY the T3Token contract with hardcoded parameters
// and estimates the cost beforehand.
// WARNING: Hardcoding private keys is insecure. Use with caution.

const { ethers } = require("ethers"); // Use ethers directly

// --- HARDCODED PARAMETERS ---
// Replace placeholders with your actual values!
const SEPOLIA_RPC_URL = "https://blockchain.googleapis.com/v1/projects/opengpt-383917/locations/us-central1/endpoints/ethereum-sepolia/rpc?key=AIzaSyBMWQpZtdLatyD3-iq64tmFaVKsiCT7v8Q";
const DEPLOYER_PRIVATE_KEY = "5269bcb465fd08e66a8f08a4447b48018cff7785910a4180e61ee2ead010aefe"; // Replace with the private key for 0x19d...F253
const TREASURY_ADDRESS = "0x19d5Dab464B7C6a4d95f16898f133559C123F253"; // Or another address if needed
const INITIAL_ADMIN_ADDRESS = "0x19d5Dab464B7C6a4d95f16898f133559C123F253"; // Usually the deployer
const GAS_LIMIT_FOR_DEPLOYMENT = 6000000; // Gas limit to *set* for the actual deployment (needs to be >= estimated gas)
const CONTRACT_NAME = "T3Token";
// --------------------------

async function main() {
  console.log(`Starting deployment process for ${CONTRACT_NAME} with hardcoded parameters...`);
  console.log(`Using RPC URL: ${SEPOLIA_RPC_URL}`);

  // 1. Set up provider and wallet
  if (!SEPOLIA_RPC_URL || SEPOLIA_RPC_URL === "YOUR_SEPOLIA_RPC_ENDPOINT_URL") {
    console.error("❌ Error: Please replace 'YOUR_SEPOLIA_RPC_ENDPOINT_URL' with your actual Sepolia RPC URL.");
    process.exit(1);
  }
  if (!DEPLOYER_PRIVATE_KEY || DEPLOYER_PRIVATE_KEY === "0xYOUR_WALLET1_PRIVATE_KEY") {
    console.error("❌ Error: Please replace '0xYOUR_WALLET1_PRIVATE_KEY' with your actual deployer private key.");
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployerWallet = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);
  const deployerAddress = await deployerWallet.getAddress();

  console.log(`Deploying contract with account: ${deployerAddress}`);

  // Get and log balance before deployment
  const initialBalanceWei = await provider.getBalance(deployerAddress);
  console.log(`Current account balance: ${ethers.formatEther(initialBalanceWei)} ETH`);
  if (initialBalanceWei === 0n) {
      console.warn("⚠️ Warning: Deployer account has zero balance on Sepolia. Deployment will likely fail.");
  }

  try {
    // 2. Get contract factory and deployment data
    // Note: Requires compiled artifacts (run `npx hardhat compile` first)
    const contractArtifact = require(`../artifacts/contracts/${CONTRACT_NAME}.sol/${CONTRACT_NAME}.json`);
    const T3TokenFactory = new ethers.ContractFactory(
      contractArtifact.abi,
      contractArtifact.bytecode,
      deployerWallet // Signer needed for factory, though estimation uses provider
    );

    // Get the deployment transaction data (without sending)
    const deployTxData = await T3TokenFactory.getDeployTransaction(
        INITIAL_ADMIN_ADDRESS,
        TREASURY_ADDRESS
        // Note: We don't include gasLimit/gasPrice here for estimation
    );

    // 3. Estimate Gas Cost
    console.log("\nEstimating deployment gas cost...");

    // Get current fee data from the network
    const feeData = await provider.getFeeData();
    console.log("   Current Fee Data (approx):");
    console.log(`     Max Fee Per Gas: ${ethers.formatUnits(feeData.maxFeePerGas || 0n, 'gwei')} gwei`);
    console.log(`     Max Priority Fee Per Gas: ${ethers.formatUnits(feeData.maxPriorityFeePerGas || 0n, 'gwei')} gwei`);

    if (!feeData.maxFeePerGas) {
        console.warn("   ⚠️ Warning: Could not retrieve maxFeePerGas from provider. Estimation might be inaccurate.");
        // Optionally set a default or throw an error
    }

    // Estimate gas units required for the deployment transaction
    const estimatedGasUnits = await provider.estimateGas(deployTxData);
    console.log(`   Estimated Gas Units Required: ${estimatedGasUnits.toString()}`);

    // Calculate estimated cost using current maxFeePerGas
    // (Actual cost depends on baseFee + priorityFee when mined)
    const estimatedCostWei = estimatedGasUnits * (feeData.maxFeePerGas || 0n); // Use maxFeePerGas for a safe upper bound estimate
    console.log(`   Estimated Max Cost: ${ethers.formatEther(estimatedCostWei)} ETH`);

    // Compare with balance
    if (estimatedCostWei > initialBalanceWei) {
        console.error(`\n❌ Error: Estimated deployment cost (${ethers.formatEther(estimatedCostWei)} ETH) exceeds current balance (${ethers.formatEther(initialBalanceWei)} ETH).`);
        console.error("   Please add more Sepolia ETH to the deployer account.");
        process.exit(1);
    } else {
        console.log("   ✅ Account balance appears sufficient for estimated cost.");
    }

    // --- Optional: Add a confirmation step here if desired ---
     const prompts = require('prompts');
     const response = await prompts({ type: 'confirm', name: 'value', message: 'Proceed with deployment?' });
     if (!response.value) {
       console.log("Deployment cancelled by user.");
       process.exit(0);
     }
    // ---------------------------------------------------------

    // 4. Deploy T3Token (Actual Deployment)
    console.log(`\nDeploying ${CONTRACT_NAME} with Gas Limit: ${GAS_LIMIT_FOR_DEPLOYMENT}...`);

    const t3Token = await T3TokenFactory.deploy(
      INITIAL_ADMIN_ADDRESS,
      TREASURY_ADDRESS,
      {
        gasLimit: GAS_LIMIT_FOR_DEPLOYMENT, // Use the hardcoded limit for the actual send
        maxFeePerGas: feeData.maxFeePerGas, // Use fetched fee data
        maxPriorityFeePerGas: feeData.maxPriorityFeePerGas // Use fetched fee data
      }
    );
    console.log(`   --> ${CONTRACT_NAME} deployment transaction sent!`);

    const deployTx = t3Token.deploymentTransaction();
     if (!deployTx) {
         console.error("   !!! Could not get deployment transaction details.");
    } else {
        console.log(`   --> Tx Hash: ${deployTx.hash}`);
        console.log(`       (Check on Sepolia Etherscan: https://sepolia.etherscan.io/tx/${deployTx.hash})`);
    }

    console.log(`   --> Waiting for ${CONTRACT_NAME} deployment transaction to be mined...`);
    const receipt = await t3Token.waitForDeployment(); // Wait for mining

    const t3TokenAddress = await t3Token.getAddress();
    console.log(`\n✅ ${CONTRACT_NAME} deployed successfully!`);
    console.log(`   Address: ${t3TokenAddress}`);

    // Log actual cost from receipt
    const actualGasUsed = receipt.gasUsed;
    const actualGasPrice = receipt.gasPrice; // Note: gasPrice is set even for EIP-1559 txs in the receipt
    const actualCostWei = actualGasUsed * actualGasPrice;
    console.log(`   Actual Gas Used: ${actualGasUsed.toString()}`);
    console.log(`   Effective Gas Price: ${ethers.formatUnits(actualGasPrice, 'gwei')} gwei`);
    console.log(`   Actual Deployment Cost: ${ethers.formatEther(actualCostWei)} ETH`);

    // Log final balance change
    const finalBalanceWei = await provider.getBalance(deployerAddress);
    const costWei = initialBalanceWei - finalBalanceWei;
    console.log(`   Balance change: ${ethers.formatEther(costWei)} ETH`);


    console.log("\n--------------------------------------------------");
    console.log("Deployment Details:");
    console.log(`   Contract Address: ${t3TokenAddress}`);
    console.log(`   Deployer: ${deployerAddress}`);
    console.log(`   Initial Admin: ${INITIAL_ADMIN_ADDRESS}`);
    console.log(`   Treasury: ${TREASURY_ADDRESS}`);
    console.log("--------------------------------------------------");


  } catch (error) {
    console.error(`\n❌ Deployment failed for ${CONTRACT_NAME}:`);
    console.error(error);
    process.exit(1); // Exit with error code
  }
}

// Execute the script
main().catch((error) => {
  console.error("❌ Unhandled error during script execution:");
  console.error(error);
  process.exit(1);
});
