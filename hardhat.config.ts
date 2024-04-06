import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomiclabs/hardhat-web3";
import '@openzeppelin/hardhat-upgrades'
import "@nomicfoundation/hardhat-ethers";
import '@nomicfoundation/hardhat-chai-matchers'
import 'solidity-coverage'

const config: HardhatUserConfig = {
  solidity: "0.8.24",
  networks: {
    hardhat: {
      chainId: 1337
    }
  }
};

export default config;
