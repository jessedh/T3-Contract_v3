const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

// Load environment variables
const SEPOLIA_RPC_URL = "https://blockchain.googleapis.com/v1/projects/opengpt-383917/locations/us-central1/endpoints/ethereum-sepolia/rpc?key=AIzaSyBMWQpZtdLatyD3-iq64tmFaVKsiCT7v8Q";
const DEPLOYER_PRIVATE_KEY = process.env.WALLET1_PRIVATE_KEY; // Updated to WALLET1_PRIVATE_KEY

// Contract details
const CONTRACT_NAME = "T3Token";
const ARTIFACTS_PATH = path.join(__dirname, "../artifacts/contracts", `${CONTRACT_NAME}.sol`, `${CONTRACT_NAME}.json`);

async function main() {
    if (!DEPLOYER_PRIVATE_KEY || !DEPLOYER_PRIVATE_KEY.startsWith("0x")) {
        throw new Error("WALLET1_PRIVATE_KEY environment variable is not set correctly (must start with 0x).");
    }

    // Set up provider and wallet
    const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
    const wallet = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

    console.log(`Deploying ${CONTRACT_NAME} with the account: ${wallet.address}`);

    // Check deployer's balance
    const balance = await provider.getBalance(wallet.address);
    console.log(`Deployer balance: ${ethers.formatEther(balance)} ETH`);

    if (balance <= ethers.parseEther("0.001")) {
        throw new Error("Insufficient balance for deployment on Sepolia testnet.");
    }

    // Load contract artifact
    const contractArtifact = JSON.parse(fs.readFileSync(ARTIFACTS_PATH, "utf8"));

    // Create ContractFactory
    const factory = new ethers.ContractFactory(contractArtifact.abi, contractArtifact.bytecode, wallet);

    // Deploy contract (adjust constructor args if needed)
    const contract = await factory.deploy();

    console.log("Deploy transaction sent. Waiting for confirmation...");

    // Wait for the contract to be mined
    await contract.waitForDeployment();

    console.log(`Contract deployed at address: ${await contract.getAddress()}`);
}

main().catch((error) => {
    console.error("Error deploying contract:", error);
    process.exitCode = 1;
});
