import { expect } from "chai";
import { ethers } from "hardhat";

enum EnumMatch {
  Sent, Started, Voting, Finished, Frozen, Disputed
}

const NULL_ADDRESS = "0x0000000000000000000000000000000000000000"
const MM_PRICE = 1_000
const BASE_MINT_AMOUNT = MM_PRICE * 1e1

async function loadFixtures() {
  const [owner, initiator, opponent] = await ethers.getSigners();
  const moneymatchrFactory = await ethers.getContractFactory("Moneymatchr")
  const smashprosFactory = await ethers.getContractFactory("Smashpros")
  const smashpros = await smashprosFactory.deploy(owner)
  const moneymatchr = await moneymatchrFactory.deploy(owner, smashpros)

  await smashpros.mint(opponent, BASE_MINT_AMOUNT)
  await smashpros.mint(initiator, BASE_MINT_AMOUNT)

  await smashpros.connect(initiator).approve(moneymatchr, BASE_MINT_AMOUNT)  
  await smashpros.connect(opponent).approve(moneymatchr, BASE_MINT_AMOUNT)

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

describe("Moneymatchr", function () {
  describe('deployment', () => {
    it("deploys and sets Smashpros token address", async function () {
      const { moneymatchr, smashpros } = await loadFixtures()
  
      expect(await moneymatchr.Smashpros()).to.equal(smashpros);
    });
  
    it("fails to deploy for contract 0x00...", async function () {
      const { moneymatchrFactory, owner } = await loadFixtures()
      
      try {
        await moneymatchrFactory.deploy(owner, NULL_ADDRESS)
      } catch(e: any) {
        expect(e.message).to.contain("Needs token address"); 
      }
    });
  
    it("fails to deploy for signer 0x00...", async function () {
      const { moneymatchrFactory, smashpros } = await loadFixtures()
      
      try {
        await moneymatchrFactory.deploy(NULL_ADDRESS, smashpros)
      } catch(e: any) {
        expect(e.message).to.contain("OwnableInvalidOwner"); 
      }
    });

    it('should grand moderator role to owner', async () => {
      const { moneymatchr, owner } = await loadFixtures()

      const moderatorRole = await moneymatchr.MATCH_MODERATOR()
      expect(await moneymatchr.hasRole(moderatorRole, owner)).to.equal(true);
    })
  })

  describe('start function', () => {
    it('should fail if user has not enough tokens', async () => {
      const { moneymatchr, initiator, opponent } = await loadFixtures()

      try {
        await moneymatchr.connect(initiator).start(opponent, BASE_MINT_AMOUNT + 1, 3)
      } catch (error: any) {
        expect(error.message).to.contain('Not enough SMSH tokens')
      }
    })

    it('should fail if opponent is 0x00...', async () => {
      const { moneymatchr } = await loadFixtures()

      try {
        await moneymatchr.start(NULL_ADDRESS, MM_PRICE, 3)
      } catch (error: any) {
        expect(error.message).to.contain('Opponent must not be null address')
      }
    })

    it('should fail if opponent is sender', async () => {
      const { moneymatchr, initiator } = await loadFixtures()

      try {
        await moneymatchr.connect(initiator).start(initiator, MM_PRICE, 3)
      } catch (error: any) {
        expect(error.message).to.contain('You cannot face yourself in a moneymatch')
      }
    })

    it('starts a match with the correct values and balances', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures()

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      const match = await moneymatchr.connect(initiator).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(MM_PRICE)

      expect(match.initiator).to.equal(initiator.address)
      expect(match.opponent).to.equal(opponent.address)
      expect(match.amount).to.equal(ethers.toBigInt(MM_PRICE))
      expect(match.state).to.equal(EnumMatch.Sent)
    })
  })

  describe('accept match function', () => {
    it('accepts match from opponent', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures()

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      await moneymatchr.connect(opponent).accept(initiator, MM_PRICE)

      const match = await moneymatchr.connect(opponent).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(MM_PRICE * 2)
      expect(match.amount).to.equal(ethers.toBigInt(MM_PRICE + MM_PRICE))
      expect(match.state).to.equal(EnumMatch.Started)
    })
  })

  describe('decline match function', () => {
    it('declines match from opponent', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures()

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)

      await moneymatchr.connect(opponent).decline(initiator)
      const match = await moneymatchr.connect(opponent).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(0)

      expect(match.amount).to.equal(ethers.toBigInt(0))
      expect(match.initiator).to.equal(NULL_ADDRESS)
      expect(match.opponent).to.equal(NULL_ADDRESS)
    })
  })

  describe('agree function', () => {
    it('initiator should agree to vote for initiator', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures() 

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      await moneymatchr.connect(opponent).accept(initiator, MM_PRICE)

      await moneymatchr.connect(initiator).agree(initiator, initiator)

      const match = await moneymatchr.connect(initiator).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(MM_PRICE * 2)
      expect(match.initiatorScore).to.equal(0)
      expect(match.opponentScore).to.equal(0)
      expect(match.winner).to.equal(NULL_ADDRESS)
      expect(match.state).to.equal(EnumMatch.Voting)
      expect(match.initiatorAgreement).to.equal(initiator)
      expect(match.opponentAgreement).to.equal(NULL_ADDRESS)
    })

    it('should vote for initiator by opponent', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures() 

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      await moneymatchr.connect(opponent).accept(initiator, MM_PRICE)

      await moneymatchr.connect(opponent).agree(initiator, initiator)

      const match = await moneymatchr.connect(initiator).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(MM_PRICE * 2)
      expect(match.initiatorScore).to.equal(0)
      expect(match.opponentScore).to.equal(0)
      expect(match.winner).to.equal(NULL_ADDRESS)
      expect(match.state).to.equal(EnumMatch.Voting)
      expect(match.initiatorAgreement).to.equal(NULL_ADDRESS)
      expect(match.opponentAgreement).to.equal(initiator)
    })

    it('initiator should agree to vote for opponent', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures() 

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      await moneymatchr.connect(opponent).accept(initiator, MM_PRICE)

      await moneymatchr.connect(initiator).agree(initiator, opponent)

      const match = await moneymatchr.connect(initiator).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(MM_PRICE * 2)
      expect(match.initiatorScore).to.equal(0)
      expect(match.opponentScore).to.equal(0)
      expect(match.winner).to.equal(NULL_ADDRESS)
      expect(match.state).to.equal(EnumMatch.Voting)
      expect(match.initiatorAgreement).to.equal(opponent)
      expect(match.opponentAgreement).to.equal(NULL_ADDRESS)
    })

    it('should vote for opponent by opponent', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures() 

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      await moneymatchr.connect(opponent).accept(initiator, MM_PRICE)

      await moneymatchr.connect(opponent).agree(initiator, opponent)

      const match = await moneymatchr.connect(initiator).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(MM_PRICE * 2)
      expect(match.initiatorScore).to.equal(0)
      expect(match.opponentScore).to.equal(0)
      expect(match.winner).to.equal(NULL_ADDRESS)
      expect(match.state).to.equal(EnumMatch.Voting)
      expect(match.initiatorAgreement).to.equal(NULL_ADDRESS)
      expect(match.opponentAgreement).to.equal(opponent)
    })

    it('should increment win counter for initiator if both agrees', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures() 

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      await moneymatchr.connect(opponent).accept(initiator, MM_PRICE)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, initiator)

      const match = await moneymatchr.connect(initiator).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(MM_PRICE * 2)
      expect(match.initiatorScore).to.equal(1)
      expect(match.opponentScore).to.equal(0)
      expect(match.winner).to.equal(NULL_ADDRESS)
      expect(match.state).to.equal(EnumMatch.Started)
      expect(match.initiatorAgreement).to.equal(NULL_ADDRESS)
      expect(match.opponentAgreement).to.equal(NULL_ADDRESS)
      expect(match.attempts).to.equal(0)
    })

    it('should increment win counter for opponent if both agrees', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures() 

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      await moneymatchr.connect(opponent).accept(initiator, MM_PRICE)

      await moneymatchr.connect(initiator).agree(initiator, opponent)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      const match = await moneymatchr.connect(initiator).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(MM_PRICE * 2)
      expect(match.initiatorScore).to.equal(0)
      expect(match.opponentScore).to.equal(1)
      expect(match.winner).to.equal(NULL_ADDRESS)
      expect(match.state).to.equal(EnumMatch.Started)
      expect(match.initiatorAgreement).to.equal(NULL_ADDRESS)
      expect(match.opponentAgreement).to.equal(NULL_ADDRESS)
      expect(match.attempts).to.equal(0)
    })

    it('should make initiator win and distribute rewards', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures() 

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      await moneymatchr.connect(opponent).accept(initiator, MM_PRICE)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, initiator)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, initiator)

      const match = await moneymatchr.connect(initiator).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT + MM_PRICE)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(0)
      expect(match.initiatorScore).to.equal(2)
      expect(match.opponentScore).to.equal(0)
      expect(match.winner).to.equal(initiator)
      expect(match.state).to.equal(EnumMatch.Finished)
      expect(match.initiatorAgreement).to.equal(NULL_ADDRESS)
      expect(match.opponentAgreement).to.equal(NULL_ADDRESS)
      expect(match.attempts).to.equal(0)
    })

    it('should make opponent win and distribute rewards', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures() 

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      await moneymatchr.connect(opponent).accept(initiator, MM_PRICE)

      await moneymatchr.connect(initiator).agree(initiator, opponent)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      await moneymatchr.connect(initiator).agree(initiator, opponent)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      const match = await moneymatchr.connect(initiator).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT + MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(0)
      expect(match.initiatorScore).to.equal(0)
      expect(match.opponentScore).to.equal(2)
      expect(match.winner).to.equal(opponent)
      expect(match.state).to.equal(EnumMatch.Finished)
      expect(match.initiatorAgreement).to.equal(NULL_ADDRESS)
      expect(match.opponentAgreement).to.equal(NULL_ADDRESS)
      expect(match.attempts).to.equal(0)
    })

    it('should increase attempts if users disagree on round winner', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures() 

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      await moneymatchr.connect(opponent).accept(initiator, MM_PRICE)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      const match = await moneymatchr.connect(initiator).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(MM_PRICE * 2)
      expect(match.initiatorScore).to.equal(0)
      expect(match.opponentScore).to.equal(0)
      expect(match.winner).to.equal(NULL_ADDRESS)
      expect(match.state).to.equal(EnumMatch.Voting)
      expect(match.initiatorAgreement).to.equal(NULL_ADDRESS)
      expect(match.opponentAgreement).to.equal(NULL_ADDRESS)
      expect(match.attempts).to.equal(1);
    })

    it('should freeze the match if user disagreed in maxAgreementAttempts times in a row', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures() 

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      await moneymatchr.connect(opponent).accept(initiator, MM_PRICE)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      const match = await moneymatchr.connect(initiator).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(MM_PRICE * 2)
      expect(match.initiatorScore).to.equal(0)
      expect(match.opponentScore).to.equal(0)
      expect(match.winner).to.equal(NULL_ADDRESS)
      expect(match.state).to.equal(EnumMatch.Frozen)
      expect(match.frozen).to.equal(true)
      expect(match.initiatorAgreement).to.equal(NULL_ADDRESS)
      expect(match.opponentAgreement).to.equal(NULL_ADDRESS)
      expect(match.attempts).to.equal(3)
    })

    it('should not freeze match and reset attempts', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures() 

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      await moneymatchr.connect(opponent).accept(initiator, MM_PRICE)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, initiator)

      const match = await moneymatchr.connect(initiator).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(MM_PRICE * 2)
      expect(match.initiatorScore).to.equal(1)
      expect(match.opponentScore).to.equal(0)
      expect(match.winner).to.equal(NULL_ADDRESS)
      expect(match.state).to.equal(EnumMatch.Started)
      expect(match.frozen).to.equal(false)
      expect(match.initiatorAgreement).to.equal(NULL_ADDRESS)
      expect(match.opponentAgreement).to.equal(NULL_ADDRESS)
      expect(match.attempts).to.equal(0)
    })
  })

  describe('emergencyWithdraw function', () => {
    it('should only be called by moderator', async () => {
      const { moneymatchr, initiator, opponent, smashpros } = await loadFixtures() 

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      await moneymatchr.connect(opponent).accept(initiator, MM_PRICE)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      try {
        await moneymatchr.connect(initiator).emergencyWithdraw(initiator)
      } catch (error: any) {
        expect(error.message).to.contain('AccessControlUnauthorizedAccount')
      }

      const match = await moneymatchr.connect(initiator).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT - MM_PRICE)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(MM_PRICE * 2)
      expect(match.initiatorScore).to.equal(0)
      expect(match.opponentScore).to.equal(0)
      expect(match.winner).to.equal(NULL_ADDRESS)
      expect(match.state).to.equal(EnumMatch.Frozen)
      expect(match.initiatorAgreement).to.equal(NULL_ADDRESS)
      expect(match.opponentAgreement).to.equal(NULL_ADDRESS)
      expect(match.attempts).to.equal(3)
      expect(match.frozen).to.equal(true)
    })

    it('should send funds back to players if owner is signer', async () => {
      const { moneymatchr, initiator, opponent, smashpros, owner } = await loadFixtures() 

      await moneymatchr.connect(initiator).start(opponent, MM_PRICE, 3)
      await moneymatchr.connect(opponent).accept(initiator, MM_PRICE)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, initiator)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      await moneymatchr.connect(initiator).agree(initiator, initiator)
      await moneymatchr.connect(opponent).agree(initiator, opponent)

      await moneymatchr.connect(owner).emergencyWithdraw(initiator)

      const match = await moneymatchr.connect(initiator).getMatch(initiator)

      expect(await smashpros.balanceOf(initiator)).to.equal(BASE_MINT_AMOUNT)
      expect(await smashpros.balanceOf(opponent)).to.equal(BASE_MINT_AMOUNT)
      expect(await smashpros.balanceOf(moneymatchr)).to.equal(0)
      expect(match.initiatorScore).to.equal(1)
      expect(match.opponentScore).to.equal(0)
      expect(match.winner).to.equal(NULL_ADDRESS)
      expect(match.state).to.equal(EnumMatch.Disputed)
      expect(match.initiatorAgreement).to.equal(NULL_ADDRESS)
      expect(match.opponentAgreement).to.equal(NULL_ADDRESS)
      expect(match.attempts).to.equal(3)
      expect(match.frozen).to.equal(true)
    })
  })
})