// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import "hardhat/console.sol";

enum MatchState {
    Sent, Started, Agreeing, Finished, Frozen, Disputed
}

struct Match {
    address initiator;
    address opponent;
    address winner;

    uint amount;
    uint maxMatches;

    uint initiatorScore;
    uint opponentScore;

    address initiatorAgreement;
    address opponentAgreement;
    uint attempts;

    bool frozen;
    MatchState state;
}


contract Moneymatchr is Ownable {
    uint public immutable maxAgreementAttempts = 3;
    ERC20 public immutable Smashpros;
    mapping (address => Match) matchs;

    constructor(address initialOwner, address _Smashpros) Ownable(initialOwner) {
        require(_Smashpros != address(0), "Needs token address");
        Smashpros = ERC20(_Smashpros);
    }

    modifier onlyMatch(address _match) {
        require(matchs[_match].initiator == msg.sender || matchs[_match].opponent == msg.sender, "Not in the match");
        _;
    }

    modifier startedMatch(address _match) {
        require(matchs[_match].state == MatchState.Started, "Match did not start");
        _;
    }

    function getMatch(address _initiator) external view returns (Match memory) {
        return matchs[_initiator];
    }

    function start(address opponent, uint amount, uint maxMatches) external returns (bool) {
        require(opponent != address(0), "Opponent must not be null address");
        require(opponent != msg.sender, "You cannot face yourself in a moneymatch");
        require(maxMatches % 2 != 0, "maxMatches must be odd");
        require(amount > 0, "Positive amount is required");
        require(Smashpros.balanceOf(msg.sender) >= amount, "Not enough SMSH tokens");
        require(Smashpros.allowance(msg.sender, address(this)) >= amount, "Contract not approved to spend tokens");

        matchs[msg.sender] = Match({
            initiator: msg.sender,
            opponent: opponent,
            winner: address(0),
            amount: amount,
            maxMatches: maxMatches,
            initiatorScore: 0,
            opponentScore: 0,
            initiatorAgreement: address(0),
            opponentAgreement: address(0),
            attempts: 0,
            frozen: false,
            state: MatchState.Sent
        });

        Smashpros.transferFrom(
            msg.sender,
            address(this),
            amount
        );

        return true;
    }

    function accept(address initiator, uint amount) external returns(bool) {
        require(initiator != address(0), "Initiator must not be null address");
        require(initiator != msg.sender, "You cannot accept your own match");

        Match storage m = matchs[initiator];

        require(m.amount == amount, "Amount should be the same as agreed");
        require(m.opponent == msg.sender, "Signer must be the opponent");
        require(Smashpros.balanceOf(msg.sender) >= amount, "Not enough SMSH tokens");

        Smashpros.transferFrom(
            msg.sender,
            address(this),
            amount
        );

        m.amount += amount;
        m.state = MatchState.Started;

        return true;
    }

    function decline(address initiator) external returns(bool) {
        require(initiator != address(0), "Initiator must not be null address");
        require(initiator != msg.sender, "You cannot refuse your own match"); 

        Match storage m = matchs[initiator];

        require(m.opponent == msg.sender, "Signer must be the opponent");

        withdraw(m.initiator,m.amount);
        delete matchs[initiator];

        return true;
    }

    function addWin(address initiator) onlyMatch(initiator) startedMatch(initiator) external returns (bool) {
        Match storage m = matchs[initiator];
        require(m.initiator != address(0), "Match does not exist");

        uint limit = (m.maxMatches/2) + 1;

        if (m.initiator == msg.sender) {
            if (limit == m.initiatorScore + 1) {
                m.state = MatchState.Agreeing;
            }

            m.initiatorScore += 1;
        } else if (m.opponent == msg.sender) {
            if (limit == m.opponentScore + 1) {
                m.state = MatchState.Agreeing;
            }

            m.opponentScore += 1;
        } else {
            return false;
        }
        
        return true;
    }

    function agree(address initiator, address on) onlyMatch(initiator) external returns (bool) {
        Match storage m = matchs[initiator];
        require(m.state == MatchState.Agreeing, "Match state must be in agreeing state to vote");

        if (m.initiator == msg.sender) {
            m.initiatorAgreement = on;

            if (m.opponentAgreement != address(0)) {
                if (m.opponentAgreement == on) {
                    win(initiator, on, m.amount);
                } else {
                    resetVotes(initiator);
                }
            }
        } else if (m.opponent == msg.sender) {
            m.opponentAgreement = on;

            if (m.initiatorAgreement != address(0)) {
                if (m.initiatorAgreement == on) {
                    win(initiator, on, m.amount);
                } else {
                    resetVotes(initiator);
                }
            }
        } else {
            return false;
        }

        return true;
    }

    function emergencyWithdraw(address initiator) external onlyOwner {
        require(initiator != address(0), "Need a match to emergency withdraw from");

        Match storage m = matchs[initiator];
        
        require(m.attempts <= maxAgreementAttempts, "Users can still try to have a consensus");
        require(m.frozen == true, "Match needs to be frozen to withdraw funds");
        require(m.state == MatchState.Frozen, "Match needs to be frozen to withdraw funds");

        uint amountToSend = matchs[initiator].amount / 2;
        withdraw(m.initiator, amountToSend);
        withdraw(m.opponent, amountToSend);

        m.state = MatchState.Disputed;
        m.initiatorAgreement = address(0);
        m.opponentAgreement = address(0);
        m.winner = address(0);
    }

    function resetVotes(address initiator) internal {
        Match storage m = matchs[initiator];

        m.state = MatchState.Agreeing;
        m.initiatorAgreement = address(0);
        m.opponentAgreement = address(0);
        m.attempts += 1;

        if (m.attempts == maxAgreementAttempts) {
            freeze(initiator);
        }
    }

    function freeze(address initiator) internal {
        matchs[initiator].frozen = true;
        matchs[initiator].state = MatchState.Frozen;
    }

    function withdraw(address to, uint amount) internal {
        Smashpros.transfer(to, amount);
    }

    function win(address initiator, address winner, uint amount) onlyMatch(initiator) internal returns (bool) {
        Match storage m = matchs[initiator];

        withdraw(winner, amount);

        m.state = MatchState.Finished;
        m.winner = winner;
        m.amount = 0;

        return true;
    }
}