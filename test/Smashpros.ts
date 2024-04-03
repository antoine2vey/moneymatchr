import { expect } from "chai";
import{ ethers } from "hardhat";

const TOTAL_SUPPLY = 1_000_000_000
const MM_PRICE = 1_000

describe("Smashpros", function () {
  describe('deployment', () => {
    it("deploys with totalSupply set", async function () {
      const [owner] = await ethers.getSigners();
      const smashprosFactory = await ethers.getContractFactory("Smashpros")
      const smashpros = await smashprosFactory.deploy(owner)
      const ownerBalance = await smashpros.balanceOf(owner.address);
  
      expect(await smashpros.totalSupply()).to.equal(ownerBalance);
    });
  })

  describe('allowances', () => {
    it("should not permit basic token spending for a contract", async function () {
      const [owner, opponent] = await ethers.getSigners();
      const moneymatchrFactory = await ethers.getContractFactory("Moneymatchr")
      const smashprosFactory = await ethers.getContractFactory("Smashpros")
      const smashpros = await smashprosFactory.deploy(owner)
      const moneymatchr = await moneymatchrFactory.deploy(owner, smashpros)
  
      try {
        await moneymatchr.start(opponent, MM_PRICE, 3)
      } catch (error: any) {
        expect(await error.message).to.contain('Contract not approved to spend tokens')
      }
    });
  
    it("should permit basic token spending for a contract", async function () {
      const [owner, opponent] = await ethers.getSigners();
      const moneymatchrFactory = await ethers.getContractFactory("Moneymatchr")
      const smashprosFactory = await ethers.getContractFactory("Smashpros")
      const smashpros = await smashprosFactory.deploy(owner)
      const moneymatchr = await moneymatchrFactory.deploy(owner, smashpros)
  
      await smashpros.approve(moneymatchr, MM_PRICE)  
      await moneymatchr.start(opponent, MM_PRICE, 3)

      expect(await smashpros.balanceOf(owner)).to.equal(TOTAL_SUPPLY - MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(MM_PRICE)
    });
  })
});