// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import "hardhat/console.sol";

enum MatchState {
    Sent, Started, Voting, Finished, Frozen, Disputed
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

contract Events {
    event Sent(address indexed _match, uint amount);
    event Start(address indexed _match);
    event Accepted(address indexed _match, address _from);
    event Declined(address indexed _match, address _from);
    event Agreed(address indexed _match, address _for);
    event Win(address indexed _match, address _winner);
    event Freeze(address indexed _match, address _by);
}


contract Moneymatchr is Ownable, AccessControl, Events {
    ERC20 public immutable Smashpros;
    mapping (address => Match) matchs;
    uint public immutable maxAgreementAttempts = 3;
    bytes32 public constant MATCH_MODERATOR = keccak256("MATCH_MODERATOR");

    constructor(address initialOwner, address _Smashpros) Ownable(initialOwner) {
        require(_Smashpros != address(0), "Needs token address");
        Smashpros = ERC20(_Smashpros);

       _grantRole(MATCH_MODERATOR, msg.sender);
    }

    modifier onlyMatch(address _match) {
        require(matchs[_match].initiator == msg.sender || matchs[_match].opponent == msg.sender, "Not in the match");
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

    function agree(address initiator, address on) onlyMatch(initiator) external returns (bool) {
        Match storage m = matchs[initiator];
        require(m.state == MatchState.Started || m.state == MatchState.Voting, "Match state must be in voting or started state to vote");

        // Set state to voting if first vote
        if (m.state != MatchState.Voting) {
            m.state = MatchState.Voting;
        }

        if (m.initiator == msg.sender) {
            m.initiatorAgreement = on;

            if (m.opponentAgreement != address(0)) {
                if (m.opponentAgreement == on) {
                    increaseScore(initiator, on);
                } else {
                    resetVotes(initiator);
                }
            }
        } else if (m.opponent == msg.sender) {
            m.opponentAgreement = on;

            if (m.initiatorAgreement != address(0)) {
                if (m.initiatorAgreement == on) {
                    increaseScore(initiator, on);
                } else {
                    resetVotes(initiator);
                }
            }
        } else {
            return false;
        }

        return true;
    }

    function emergencyWithdraw(address initiator) external onlyRole(MATCH_MODERATOR) {
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

    function increaseScore(address initiator, address user) onlyMatch(initiator) internal returns (bool) {
        Match storage m = matchs[initiator];
        require(user != address(0), "You should increase score for an existing user");
        require(m.state == MatchState.Voting, "Match state must be in voting state to increase score");

        uint limit = (m.maxMatches / 2) + 1;

        if (m.initiator == user) {
            m.initiatorScore += 1;
            if (limit == m.initiatorScore) {
                win(initiator, user, m.amount);
                return true;
            }
        } else if (m.opponent == user) {
            m.opponentScore += 1;
            if (limit == m.opponentScore) {
                win(initiator, user, m.amount);
                return true;
            }
        } else {
            return false;
        }

        m.state = MatchState.Started;
        m.initiatorAgreement = address(0);
        m.opponentAgreement = address(0);
        m.attempts = 0;
        return true;
    }

    function resetVotes(address initiator) internal {
        Match storage m = matchs[initiator];

        m.state = MatchState.Voting;
        m.initiatorAgreement = address(0);
        m.opponentAgreement = address(0);
        m.attempts += 1;

        if (m.attempts == maxAgreementAttempts) {
            freeze(initiator);
        }
    }

    function freeze(address initiator) internal {
        matchs[initiator].state = MatchState.Frozen;
        matchs[initiator].frozen = true;
    }

    function withdraw(address to, uint amount) internal {
        Smashpros.transfer(to, amount);
    }

    function win(address initiator, address winner, uint amount) onlyMatch(initiator) internal returns (bool) {
        Match storage m = matchs[initiator];

        withdraw(winner, amount);

        m.state = MatchState.Finished;
        m.initiatorAgreement = address(0);
        m.opponentAgreement = address(0);
        m.attempts = 0;
        m.winner = winner;
        m.amount = 0;

        return true;
    }
}