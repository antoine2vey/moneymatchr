// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import "hardhat/console.sol";

// Match state for events
enum MatchState {
    Sent, Started, Voting, Finished, Frozen, Disputed
}

// Match structure for Moneymatchr
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

// Basic interface for Moneymatchr
interface IMoneymatchr {
    event Send(address indexed _to, uint256 _id);
    event Accept(uint256 indexed _id);
    event Decline(uint256 indexed _id);
    event Agree(uint256 indexed _id, address indexed _from, address _for);
    event Win(uint256 indexed _id, address _winner);
    event Freeze(uint256 indexed _id);

    function start(address opponent, uint amount, uint maxMatches) external returns (bool);
    function accept(uint256 id, uint amount) external returns(bool);
    function decline(uint256 id) external returns(bool);
    function agree(uint256 id, address on) external returns (bool);
    function emergencyWithdraw(uint256 id) external;
}


contract Moneymatchr is Ownable, AccessControl, IMoneymatchr {
    // Smashpros or any ERC20 token
    ERC20 public immutable Smashpros;
    // All moneymatches in the contract
    mapping (uint256 => Match) matchs;
    // Match ids
    mapping (address => uint256[]) ids;
    // Match starting id
    uint256 startingId = 0;
    // Max agreement attemps (todo modify it from public functions)
    uint public immutable maxAgreementAttempts = 3;
    // keccak256(MATCH_MODERATOR)
    bytes32 public constant MATCH_MODERATOR = 0xb112e0c9ec8e3f5cff835bd9eeab690a544692d98f1876a66929cf8426dd820a;

    constructor(address initialOwner, address _Smashpros) Ownable(initialOwner) {
        require(_Smashpros != address(0), "Needs token address");
        Smashpros = ERC20(_Smashpros);

        // Grant role match moderator to deployer
       _grantRole(MATCH_MODERATOR, initialOwner);
    }

    /**
     * @dev Ensure id is not empty and match exists
     * @param _id match id
     */
    modifier matchExists(uint256 _id) {
        require(_id != uint256(0), "Match id must not be null");
        require(matchs[_id].initiator != address(0) && matchs[_id].opponent != address(0), "Match must exists");
        _;
    }

    /**
     * @dev Checks if `msg.sender` is in a given match
     * @param _id match id
     */
    modifier onlyMatch(uint256 _id) {
        require(matchs[_id].initiator == msg.sender || matchs[_id].opponent == msg.sender, "Not in the match");
        _;
    }

    /**
     * @dev Returns a match by its id
     * @param id match id
     */
    function getMatch(uint256 id) external view returns(Match memory) {
        return matchs[id];
    }

    /**
     * @dev Get all matches for an user
     */
    function getMatchs() external view returns(Match[] memory) {
        Match[] memory userMatchs = new Match[](ids[msg.sender].length);

        for (uint i = 0; i < ids[msg.sender].length; i++) {
            userMatchs[i] = this.getMatch(ids[msg.sender][i]);
        }

        return userMatchs;
    }

    /**
     * @dev Creates a match, withdraw tokens to the contract and sends an event
     * @param opponent user to face
     * @param amount amount of ERC20 tokens
     * @param maxMatches maximum matches (must be odd)
     */
    function start(address opponent, uint amount, uint maxMatches) external returns (bool) {
        require(opponent != address(0), "Opponent must not be null address");
        require(opponent != msg.sender, "You cannot face yourself in a moneymatch");
        require(maxMatches % 2 != 0, "maxMatches must be odd");
        require(amount > 0, "Positive amount is required");
        require(Smashpros.balanceOf(msg.sender) >= amount, "Not enough SMSH tokens");
        require(Smashpros.allowance(msg.sender, address(this)) >= amount, "Contract not approved to spend tokens");
        
        startingId++;

        matchs[startingId] = Match({
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

        // Add references for both users
        ids[msg.sender].push(startingId);
        ids[opponent].push(startingId);

        // Transfer funds from signer to contract
        Smashpros.transferFrom(
            msg.sender,
            address(this),
            amount
        );

        emit Send(opponent, startingId);

        return true;
    }

    /**
     * @dev Accepts a match, transfer funds from signer to contract
     * @param id match id
     * @param amount amount of tokens
     */
    function accept(uint256 id, uint amount) matchExists(id) external returns(bool) {
        Match storage m = matchs[id];

        require(m.opponent == msg.sender, "Signer must be the opponent");
        require(m.amount == amount, "Amount should be the same as agreed");
        require(Smashpros.balanceOf(msg.sender) >= amount, "Not enough SMSH tokens");

        // Transfer funds from signer to contract if user accepted
        Smashpros.transferFrom(
            msg.sender,
            address(this),
            amount
        );

        m.amount += amount;
        m.state = MatchState.Started;

        emit Accept(id);

        return true;
    }

    /**
     * @dev Declines a match, sends funds back to the match creator
     * @param id match id
     */
    function decline(uint256 id) matchExists(id) external returns(bool) {
        Match storage m = matchs[id];

        require(m.opponent == msg.sender, "Signer must be the opponent");

        // Sends funds back to initiator
        withdraw(m.initiator, m.amount);
        // Remove references from ids for both users
        removeMatchReference(msg.sender, id);
        removeMatchReference(m.initiator, id);
        // Delete match from mapping since this match never existed
        delete matchs[id];

        emit Decline(id);

        return true;
    }

    /**
     * Makes a user agree on an user that won the round, increases score if they have an agreement
     * else, it reset votes (up to maxAgreementAttemps times)
     * @param id match id
     * @param on round winner
     */
    function agree(uint256 id, address on) matchExists(id) onlyMatch(id) external returns (bool) {
        Match storage m = matchs[id];

        require(m.state == MatchState.Started || m.state == MatchState.Voting, "Match state must be in voting or started state to vote");

        // Set state to voting if first vote
        if (m.state != MatchState.Voting) {
            m.state = MatchState.Voting;
        }

        // If signer is our initiator
        if (m.initiator == msg.sender) {
            // Register his vote
            m.initiatorAgreement = on;
            emit Agree(id, msg.sender, on);

            // If opponent agreed on someone
            if (m.opponentAgreement != address(0)) {
                // and agreed with us
                if (m.opponentAgreement == on) {
                    // Increase voted user score
                    increaseScore(id, on);
                } else {
                    // Else, votes are resetted and increase attemps
                    resetVotes(id);
                }
            }
        // If signer is our opponent
        } else if (m.opponent == msg.sender) {
            // Register his vote
            m.opponentAgreement = on;
            emit Agree(id, msg.sender, on);

            // If initiator agreed on someone
            if (m.initiatorAgreement != address(0)) {
                // and agreed with us
                if (m.initiatorAgreement == on) {
                    // Increase voted user score
                    increaseScore(id, on);
                } else {
                    // Else, votes are resetted and increase attemps
                    resetVotes(id);
                }
            }
        }

        return true;
    }

    /**
     * @dev Sends funds back to user manually if match is frozen due to disagreements, only callable
     * by MATCH_MODERATOR
     * @param id match id
     */
    function emergencyWithdraw(uint256 id) onlyRole(MATCH_MODERATOR) matchExists(id) external {
        Match storage m = matchs[id];
        
        require(m.attempts >= maxAgreementAttempts, "Users can still try to have a consensus");
        require(m.frozen == true, "Match needs to be frozen to withdraw funds");
        require(m.state == MatchState.Frozen, "Match needs to be frozen to withdraw funds");

        uint amountToSend = matchs[id].amount / 2;
        // Send funds back
        withdraw(m.initiator, amountToSend);
        withdraw(m.opponent, amountToSend);

        // Set match state to disputed
        m.state = MatchState.Disputed;
        m.initiatorAgreement = address(0);
        m.opponentAgreement = address(0);
        m.winner = address(0);
    }

    /**
     * Increase a user score, and grants him win if needed
     * @param id match id
     * @param user user to increase score
     */
    function increaseScore(uint256 id, address user) onlyMatch(id) internal returns (bool) {
        Match storage m = matchs[id];

        require(user != address(0), "You should increase score for an existing user");
        require(m.state == MatchState.Voting, "Match state must be in voting state to increase score");

        // Example: 
        // Best of 3 (first to 2 wins) = (3/2)+1 = 2
        // Best of 5 (first to 3 wins) = (5/2)+1 = 3
        uint limit = (m.maxMatches / 2) + 1;

        // If winner is initiator
        if (m.initiator == user) {
            // increase his score
            m.initiatorScore += 1;
            // and check if his score reached the limit
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
        }

        m.state = MatchState.Started;
        m.initiatorAgreement = address(0);
        m.opponentAgreement = address(0);
        m.attempts = 0;

        return true;
    }

    /**
     * @dev Reset match votes and freezes if needed
     * @param id match id
     */
    function resetVotes(uint256 id) internal {
        Match storage m = matchs[id];

        m.state = MatchState.Voting;
        m.initiatorAgreement = address(0);
        m.opponentAgreement = address(0);
        m.attempts += 1;

        // If maxAgreementAttemps is reahed, freeze the match
        if (m.attempts == maxAgreementAttempts) {
            freeze(id);
        }
    }

    /**
     * Freezes a match
     * @param id match id
     */
    function freeze(uint256 id) internal {
        matchs[id].state = MatchState.Frozen;
        matchs[id].frozen = true;

        emit Freeze(id);
    }

    /**
     * Sends token from contract to user
     * @param to user
     * @param amount amount of tokens
     */
    function withdraw(address to, uint amount) internal {
        Smashpros.transfer(to, amount);
    }

    /**
     * Sends tokens from contract to winner if and sets winner
     * @param id match id
     * @param winner user 
     * @param amount amount of token
     */
    function win(uint256 id, address winner, uint amount) onlyMatch(id) internal returns (bool) {
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

    /**
     * @dev Sets element with value to the end and pops array
     * shouldn't iterate that much on array so its fine gas wise
     * @param _id element to delete
     */
    function removeMatchReference(address _address, uint256 _id) internal {
        require(_address != address(0));
        require(_id != uint256(0));

        for (uint i = 0; i < ids[_address].length; i++) {
            if (ids[_address][i] == _id) {
                ids[_address][i] = ids[_address][ids[_address].length-1];
                ids[_address].pop();
            }
        }
    }
}