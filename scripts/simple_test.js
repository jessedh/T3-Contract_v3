// For CustodianRegistry
const CustodianRegistry = await ethers.getContractFactory("CustodianRegistry");
const cr = CustodianRegistry.attach("0x2406b0c9a5eAAc038c050a80fF3798dFfe90Ff5A"); // Attach to proxy

// Example: Check if deployer has ADMIN_ROLE (it should from initialize)
const ADMIN_ROLE = await cr.ADMIN_ROLE();
await cr.hasRole(ADMIN_ROLE, "YOUR_DEPLOYER_ADDRESS"); // Replace with actual deployer address

// For T3Token
const T3Token = await ethers.getContractFactory("T3Token");
const t3 = T3Token.attach("0x76bccC0cAE0ED9A461bD7621D8F399Fa430f93a7"); // Attach to proxy

// Example: Get token name
await t3.name();
await t3.balanceOf("YOUR_DEPLOYER_ADDRESS");