require("@nomicfoundation/hardhat-ethers");
require("@openzeppelin/hardhat-upgrades"); // For upgradeable contracts
require("dotenv").config(); // To load .env variables
require("@nomicfoundation/hardhat-chai-matchers");
//added for coverage reports
require('solidity-coverage');
//added for gas reports
require('hardhat-gas-reporter');

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24", // Ensure this matches your contract's pragma
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {},
    fuji: {
      url: process.env.FUJI_RPC_URL || "https://api.avax-test.network/ext/bc/C/rpc",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: 43113,
    },
    // You can add mainnet config later
    // avalancheMainnet: {
    //   url: 'https://api.avax.network/ext/bc/C/rpc',
    //   accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    //   chainId: 43114,
    // }
  },
  etherscan: { // Used for Snowtrace (Avalanche's Etherscan equivalent)
    apiKey: {
      avalancheFujiTestnet: process.env.SNOWTRACE_API_KEY || "0x19d5Dab464B7C6a4d95f16898f133559C123F253", // Snowtrace uses 'apiKey' object format
      // avalanche: process.env.SNOWTRACE_API_KEY // For mainnet
    }
  },
  // If you are using hardhat-verify with custom chains (like Fuji before official support was robust)
  // you might need this, but typically the above etherscan block is enough now.
  // sourcify: {
  //   enabled: true
  // }
};