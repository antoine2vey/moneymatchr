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

interface IMoneymatchr {
    event Send(bytes32 indexed _id, uint amount);
    event Accept(bytes32 indexed _id, address _from);
    event Decline(bytes32 indexed _id, address _from);
    event Agree(bytes32 indexed _id, address _from, address _for);
    event Win(bytes32 indexed _id, address _winner);
    event Freeze(bytes32 indexed _id);

    function start(address opponent, uint amount, uint maxMatches) external returns (bool);
    function accept(bytes32 id, uint amount) external returns(bool);
    function decline(bytes32 id) external returns(bool);
    function agree(bytes32 id, address on) external returns (bool);
    function emergencyWithdraw(bytes32 id) external;
}


contract Moneymatchr is Ownable, AccessControl, IMoneymatchr {
    ERC20 public immutable Smashpros;
    mapping (bytes32 => Match) matchs;
    uint public immutable maxAgreementAttempts = 3;
    bytes32 public constant MATCH_MODERATOR = keccak256("MATCH_MODERATOR");

    constructor(address initialOwner, address _Smashpros) Ownable(initialOwner) {
        require(_Smashpros != address(0), "Needs token address");
        Smashpros = ERC20(_Smashpros);

       _grantRole(MATCH_MODERATOR, msg.sender);
    }

    modifier matchExists(bytes32 _id) {
        require(_id != bytes32(0), "Match id must not be null");
        _;
    }

    modifier onlyMatch(bytes32 _id) {
        require(matchs[_id].initiator == msg.sender || matchs[_id].opponent == msg.sender, "Not in the match");
        _;
    }

    function getMatch(bytes32 id) external view returns (Match memory) {
        return matchs[id];
    }

    function start(address opponent, uint amount, uint maxMatches) external returns (bool) {
        require(opponent != address(0), "Opponent must not be null address");
        require(opponent != msg.sender, "You cannot face yourself in a moneymatch");
        require(maxMatches % 2 != 0, "maxMatches must be odd");
        require(amount > 0, "Positive amount is required");
        require(Smashpros.balanceOf(msg.sender) >= amount, "Not enough SMSH tokens");
        require(Smashpros.allowance(msg.sender, address(this)) >= amount, "Contract not approved to spend tokens");

        bytes32 id = keccak256(abi.encodePacked(msg.sender, block.timestamp, opponent, amount));

        matchs[id] = Match({
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

        emit Send(id, amount);

        return true;
    }

    function accept(bytes32 id, uint amount) matchExists(id) external returns(bool) {
        Match storage m = matchs[id];

        require(m.initiator != msg.sender, "You cannot accept your own match");
        require(m.opponent == msg.sender, "Signer must be the opponent");
        require(m.amount == amount, "Amount should be the same as agreed");
        require(Smashpros.balanceOf(msg.sender) >= amount, "Not enough SMSH tokens");

        Smashpros.transferFrom(
            msg.sender,
            address(this),
            amount
        );

        m.amount += amount;
        m.state = MatchState.Started;

        emit Accept(id, msg.sender);

        return true;
    }

    function decline(bytes32 id) matchExists(id) external returns(bool) {
        Match storage m = matchs[id];

        require(m.initiator != msg.sender, "You cannot refuse your own match"); 
        require(m.opponent == msg.sender, "Signer must be the opponent");

        withdraw(m.initiator, m.amount);
        delete matchs[id];

        emit Decline(id, msg.sender);

        return true;
    }

    function agree(bytes32 id, address on) matchExists(id) onlyMatch(id) external returns (bool) {
        Match storage m = matchs[id];

        require(m.state == MatchState.Started || m.state == MatchState.Voting, "Match state must be in voting or started state to vote");

        // Set state to voting if first vote
        if (m.state != MatchState.Voting) {
            m.state = MatchState.Voting;
        }

        if (m.initiator == msg.sender) {
            m.initiatorAgreement = on;
            emit Agree(id, msg.sender, on);

            if (m.opponentAgreement != address(0)) {
                if (m.opponentAgreement == on) {
                    increaseScore(id, on);
                } else {
                    resetVotes(id);
                }
            }
        } else if (m.opponent == msg.sender) {
            m.opponentAgreement = on;
            emit Agree(id, msg.sender, on);

            if (m.initiatorAgreement != address(0)) {
                if (m.initiatorAgreement == on) {
                    increaseScore(id, on);
                } else {
                    resetVotes(id);
                }
            }
        } else {
            return false;
        }

        return true;
    }

    function emergencyWithdraw(bytes32 id) matchExists(id) onlyRole(MATCH_MODERATOR) external {
        Match storage m = matchs[id];
        
        require(m.attempts <= maxAgreementAttempts, "Users can still try to have a consensus");
        require(m.frozen == true, "Match needs to be frozen to withdraw funds");
        require(m.state == MatchState.Frozen, "Match needs to be frozen to withdraw funds");

        uint amountToSend = matchs[id].amount / 2;
        withdraw(m.initiator, amountToSend);
        withdraw(m.opponent, amountToSend);

        m.state = MatchState.Disputed;
        m.initiatorAgreement = address(0);
        m.opponentAgreement = address(0);
        m.winner = address(0);
    }

    function increaseScore(bytes32 id, address user) onlyMatch(id) internal returns (bool) {
        Match storage m = matchs[id];

        require(user != address(0), "You should increase score for an existing user");
        require(m.state == MatchState.Voting, "Match state must be in voting state to increase score");

        uint limit = (m.maxMatches / 2) + 1;

        if (m.initiator == user) {
            m.initiatorScore += 1;
            if (limit == m.initiatorScore) {
                win(id, user, m.amount);
                return true;
            }
        } else if (m.opponent == user) {
            m.opponentScore += 1;
            if (limit == m.opponentScore) {
                win(id, user, m.amount);
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

    function resetVotes(bytes32 id) internal {
        Match storage m = matchs[id];

        m.state = MatchState.Voting;
        m.initiatorAgreement = address(0);
        m.opponentAgreement = address(0);
        m.attempts += 1;

        if (m.attempts == maxAgreementAttempts) {
            freeze(id);
        }
    }

    function freeze(bytes32 id) internal {
        matchs[id].state = MatchState.Frozen;
        matchs[id].frozen = true;

        emit Freeze(id);
    }

    function withdraw(address to, uint amount) internal {
        Smashpros.transfer(to, amount);
    }

    function win(bytes32 id, address winner, uint amount) onlyMatch(id) internal returns (bool) {
        Match storage m = matchs[id];

        withdraw(winner, amount);

        m.state = MatchState.Finished;
        m.initiatorAgreement = address(0);
        m.opponentAgreement = address(0);
        m.attempts = 0;
        m.winner = winner;
        m.amount = 0;

        emit Win(id, winner);

        return true;
    }
}