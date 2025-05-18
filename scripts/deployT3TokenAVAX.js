const { ethers, upgrades } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());
  console.log("----------------------------------------------------");

  // --- Deployment for CustodianRegistry ---
  console.log("Deploying CustodianRegistry (upgradeable UUPS proxy)...");
  const CustodianRegistryFactory = await ethers.getContractFactory("CustodianRegistry");
  const initialAdminAddressCR = deployer.address; // Or a specific admin for CustodianRegistry

  const custodianRegistryProxy = await upgrades.deployProxy(
    CustodianRegistryFactory,
    [initialAdminAddressCR], // Arguments for CustodianRegistry's initialize function
    {
      initializer: "initialize",
      kind: "uups",
      timeout: 0 // Consider adjusting if needed
    }
  );
  await custodianRegistryProxy.waitForDeployment();
  const crProxyAddress = await custodianRegistryProxy.getAddress();
  console.log("CustodianRegistry Proxy (UUPS) deployed to:", crProxyAddress);

  const crImplementationAddress = await upgrades.erc1967.getImplementationAddress(crProxyAddress);
  console.log("CustodianRegistry Implementation deployed to:", crImplementationAddress);
  console.log("----------------------------------------------------");


  // --- Deployment for T3Token ---
  console.log("Deploying T3Token (upgradeable UUPS proxy)...");
  const T3TokenFactory = await ethers.getContractFactory("T3Token");

  // Arguments for T3Token's initialize function
  const tokenName = "T3 Stablecoin";
  const tokenSymbol = "T3";
  const initialAdminAddressT3 = deployer.address; // Or a specific admin for T3Token
  
  // IMPORTANT: The T3Token `initialize` needs a treasuryAddress.
  // For now, let's assume the deployer is also the initial treasury.
  // In a real scenario, this might be a multisig or a dedicated treasury contract.
  // If your CustodianRegistry is meant to be the treasury, or if you have another treasury contract,
  // you would deploy that first and pass its address here.
  // For this example, using deployer's address as a placeholder for T3Token's treasury.
  const t3TokenTreasuryAddress = deployer.address; // <<<<< CHECK AND UPDATE THIS LOGIC AS NEEDED
                                                  // If CustodianRegistry is NOT the treasury for T3Token fees.

  const initialMintAmount = ethers.parseUnits("1000000", 18); // Example mint amount

  // Initial values for T3Token specific parameters (HalfLife, etc.)
  const initialHalfLifeDuration = 3600; // 1 hour
  const initialMinHalfLifeDuration = 600; // 10 minutes
  const initialMaxHalfLifeDuration = 86400; // 1 day
  const initialInactivityResetPeriod = 30 * 24 * 60 * 60; // 30 days in seconds

  const t3TokenProxy = await upgrades.deployProxy(
    T3TokenFactory,
    [
      tokenName,
      tokenSymbol,
      initialAdminAddressT3,
      t3TokenTreasuryAddress, // Pass the treasury address for T3Token
      initialMintAmount,
      initialHalfLifeDuration,
      initialMinHalfLifeDuration,
      initialMaxHalfLifeDuration,
      initialInactivityResetPeriod
    ],
    {
      initializer: "initialize",
      kind: "uups",
      timeout: 0 // Consider adjusting if needed
    }
  );
  await t3TokenProxy.waitForDeployment();
  const t3ProxyAddress = await t3TokenProxy.getAddress();
  console.log("T3Token Proxy (UUPS) deployed to:", t3ProxyAddress);

  const t3ImplementationAddress = await upgrades.erc1967.getImplementationAddress(t3ProxyAddress);
  console.log("T3Token Implementation deployed to:", t3ImplementationAddress);
  console.log("----------------------------------------------------");

  console.log("\nVerification Commands (run for each implementation):");
  console.log(`npx hardhat verify --network fuji ${crImplementationAddress} --contract contracts/CustodianRegistry.sol:CustodianRegistry`);
  console.log(`npx hardhat verify --network fuji ${t3ImplementationAddress} --contract contracts/T3Token.sol:T3Token`);
  console.log("\nFor proxies, check Snowtrace UI to link to implementations after verifying them.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });