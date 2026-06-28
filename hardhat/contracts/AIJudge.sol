// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
    function depositFor(address user, uint256 lockDuration) external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function lockUntil(address) external view returns (uint256);
}

contract AIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    IRitualWallet wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    // ------------------------------------------------------------------ //
    //  Commit-reveal data structures
    // ------------------------------------------------------------------ //

    struct Commitment {
        bytes32 hash;       // keccak256(answer, salt, msg.sender, bountyId)
        bool revealed;
    }

    struct Submission {
        address submitter;
        string answer;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 deadline;          // submissions close at this timestamp
        uint256 revealDeadline;    // reveals close at this timestamp (deadline + revealWindow)
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        Submission[] submissions;  // populated only after reveal phase
        mapping(address => Commitment) commitments;
        mapping(address => bool) hasCommitted;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) public bounties;

    // ------------------------------------------------------------------ //
    //  Events
    // ------------------------------------------------------------------ //

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 deadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        address indexed submitter
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    // ------------------------------------------------------------------ //
    //  Modifiers
    // ------------------------------------------------------------------ //

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    // ------------------------------------------------------------------ //
    //  Core functions
    // ------------------------------------------------------------------ //

    /**
     * @notice Create a new bounty with a commit phase and a reveal phase.
     * @param title        Human-readable title.
     * @param rubric       Judging criteria passed to the LLM.
     * @param deadline     Unix timestamp when the commit phase closes.
     * @param revealWindow Seconds after deadline during which reveals are accepted.
     */
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 deadline,
        uint256 revealWindow
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(deadline > block.timestamp, "deadline must be in the future");
        require(revealWindow > 0, "reveal window required");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.deadline = deadline;
        bounty.revealDeadline = deadline + revealWindow;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            deadline,
            deadline + revealWindow
        );
    }

    /**
     * @notice Phase 1 – submit a commitment hash.
     *         commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     */
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.deadline, "commit phase closed");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(!bounty.hasCommitted[msg.sender], "already committed");
        // Cap total committers (same spirit as original MAX_SUBMISSIONS)
        // We track via submissions length after reveal, so we keep a separate counter
        // stored implicitly: we limit by checking revealed submissions won't exceed cap.
        // A simple approach: allow up to MAX_SUBMISSIONS commitments total.
        // We don't store all committers, so we use a counter stored as submissions.length
        // before reveals start (it's 0 during commit phase). We use a dedicated counter.
        require(
            bounty.submissions.length < MAX_SUBMISSIONS,
            "too many commitments"
        );

        bounty.commitments[msg.sender] = Commitment({
            hash: commitment,
            revealed: false
        });
        bounty.hasCommitted[msg.sender] = true;

        // Temporarily push a placeholder so we can track total commitments
        // without an extra storage variable. Overwritten on reveal.
        bounty.submissions.push(Submission({submitter: msg.sender, answer: ""}));

        emit CommitmentSubmitted(bountyId, msg.sender);
    }

    /**
     * @notice Phase 2 – reveal the answer and salt.
     *         The contract verifies keccak256(answer, salt, msg.sender, bountyId)
     *         matches the stored commitment.
     */
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.deadline, "commit phase still open");
        require(block.timestamp < bounty.revealDeadline, "reveal phase closed");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.hasCommitted[msg.sender], "no commitment found");

        Commitment storage c = bounty.commitments[msg.sender];
        require(!c.revealed, "already revealed");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        bytes32 expected = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(expected == c.hash, "commitment mismatch");

        c.revealed = true;

        // Find the placeholder slot for this submitter and fill it in.
        uint256 idx = _findSubmissionIndex(bounty, msg.sender);
        bounty.submissions[idx].answer = answer;

        emit AnswerRevealed(bountyId, idx, msg.sender);
    }

    /**
     * @notice Phase 3 – send all revealed answers to the LLM for batch judging.
     *         Only the bounty owner can call this, and only after the reveal phase closes.
     */
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.revealDeadline, "reveal phase still open");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(_revealedCount(bounty) > 0, "no revealed submissions");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    /**
     * @notice Phase 4 – owner finalizes the winner by index (among revealed submissions).
     */
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid index");

        Submission storage winner = bounty.submissions[winnerIndex];
        require(bytes(winner.answer).length > 0, "winner did not reveal");

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winnerAddr = winner.submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winnerAddr).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winnerAddr, reward);
    }

    // ------------------------------------------------------------------ //
    //  View helpers
    // ------------------------------------------------------------------ //

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 deadline,
            uint256 revealDeadline,
            bool judged,
            bool finalized,
            uint256 submissionCount,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage bounty = bounties[bountyId];
        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.deadline,
            bounty.revealDeadline,
            bounty.judged,
            bounty.finalized,
            bounty.submissions.length,
            bounty.winnerIndex,
            bounty.aiReview
        );
    }

    /**
     * @notice Returns submission data. Answer is empty string until the submitter reveals.
     */
    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, string memory answer, bool revealed)
    {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.submissions.length, "invalid index");

        Submission storage sub = bounty.submissions[index];
        bool isRevealed = bounty.hasCommitted[sub.submitter] &&
            bounty.commitments[sub.submitter].revealed;

        return (sub.submitter, sub.answer, isRevealed);
    }

    /**
     * @notice Returns whether a given address has committed to a bounty.
     */
    function hasCommitted(
        uint256 bountyId,
        address submitter
    ) external view bountyExists(bountyId) returns (bool) {
        return bounties[bountyId].hasCommitted[submitter];
    }

    /**
     * @notice Returns the commitment hash for a given address (for debugging / UI).
     */
    function getCommitment(
        uint256 bountyId,
        address submitter
    ) external view bountyExists(bountyId) returns (bytes32 hash, bool revealed) {
        Commitment storage c = bounties[bountyId].commitments[submitter];
        return (c.hash, c.revealed);
    }

    // ------------------------------------------------------------------ //
    //  Internal helpers
    // ------------------------------------------------------------------ //

    function _findSubmissionIndex(
        Bounty storage bounty,
        address submitter
    ) internal view returns (uint256) {
        for (uint256 i = 0; i < bounty.submissions.length; i++) {
            if (bounty.submissions[i].submitter == submitter) {
                return i;
            }
        }
        revert("submitter slot not found");
    }

    function _revealedCount(
        Bounty storage bounty
    ) internal view returns (uint256 count) {
        for (uint256 i = 0; i < bounty.submissions.length; i++) {
            address s = bounty.submissions[i].submitter;
            if (bounty.commitments[s].revealed) {
                count++;
            }
        }
    }
}
