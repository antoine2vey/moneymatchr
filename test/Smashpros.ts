import { expect } from "chai";
import{ ethers } from "hardhat";

const NULL_ADDRESS = "0x0000000000000000000000000000000000000000"
const MM_PRICE = 1_000
const BASE_MINT_AMOUNT = MM_PRICE * 1e1

async function loadFixtures(enableApprove = true, enableMinting = true) {
  const [owner, initiator, opponent] = await ethers.getSigners()
  const moneymatchrFactory = await ethers.getContractFactory("Moneymatchr")
  const smashprosFactory = await ethers.getContractFactory("Smashpros")
  const smashpros = await smashprosFactory.deploy(owner)
  const moneymatchr = await moneymatchrFactory.deploy(owner, smashpros)

  if (enableMinting) {
    await smashpros.mint(opponent, BASE_MINT_AMOUNT)
    await smashpros.mint(initiator, BASE_MINT_AMOUNT)
  }

  if (enableApprove) {
    await smashpros.connect(initiator).approve(moneymatchr, BASE_MINT_AMOUNT)  
    await smashpros.connect(opponent).approve(moneymatchr, BASE_MINT_AMOUNT)
  }

  return {
    owner,
    initiator,
    opponent,
    smashpros,
    moneymatchr,
    smashprosFactory,
    moneymatchrFactory
  }
}

describe("Smashpros", function () {
  describe('deployment', async () => {
    it('should deploy contract with name', async () => {
      const { smashpros } = await loadFixtures()
      expect(await smashpros.name()).to.equal("Smashpros")
    })

    it('should deploy contract with ticker', async () => {
      const { smashpros } = await loadFixtures()
      expect(await smashpros.symbol()).to.equal("SMSH")
    })
  })

  describe('token minting', () => {
    it('should mint token if owner is sender', async () => {
      const { initiator, smashpros, owner } = await loadFixtures(false, false)

      await expect(smashpros.connect(owner).mint(initiator, BASE_MINT_AMOUNT))
        .to.changeTokenBalances(
          smashpros,
          [initiator],
          [BASE_MINT_AMOUNT]
        )
    })

    it('should not mint token if owner is not sender', async () => {
      const { initiator, smashpros } = await loadFixtures(false, false)

      await expect(smashpros.connect(initiator).mint(initiator, BASE_MINT_AMOUNT))
        .to.revertedWithCustomError(smashpros, 'OwnableUnauthorizedAccount')
    })
  })

  describe('smashpros allowances', () => {
    it("should not permit basic token spending for a contract", async function () {
      const { moneymatchr, initiator, opponent } = await loadFixtures(false)
  
      await expect(moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3))
        .to.be.revertedWith('Contract not approved to spend tokens')
    });
  
    it("should permit basic token spending for a contract", async function () {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures(false)
  
      await smashpros.connect(initiator).approve(moneymatchr, MM_PRICE)

      await expect(moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3))
        .to.changeTokenBalances(
          smashpros,
          [initiator, moneymatchr],
          [-MM_PRICE, +MM_PRICE]
        )
    });
  })
});