# Privacy-Preserving AI Bounty Judge – Commit-Reveal Implementation

## Overview

This fork adds a **commit-reveal scheme** to the original `AIJudge` contract so that participants cannot copy each other's answers before judging. Submissions stay hidden on-chain until the reveal phase closes, at which point the bounty owner triggers a single batch LLM call via Ritual.

---

## Lifecycle

```
createBounty()
      │
      ▼
[COMMIT PHASE]  (block.timestamp < deadline)
  submitCommitment(bountyId, keccak256(answer ‖ salt ‖ msg.sender ‖ bountyId))
      │
      ▼  deadline passes
[REVEAL PHASE]  (deadline ≤ block.timestamp < revealDeadline)
  revealAnswer(bountyId, answer, salt)  — contract re-derives and checks the hash
      │
      ▼  revealDeadline passes
[JUDGING]
  judgeAll(bountyId, llmInput)          — owner sends all revealed answers to Ritual LLM
      │
      ▼
[FINALIZATION]
  finalizeWinner(bountyId, winnerIndex) — owner picks winner; ETH transferred automatically
```

---

## Contract Changes vs Original

| Area | Original | New |
|---|---|---|
| Submission | `submitAnswer()` stores plaintext immediately | `submitCommitment()` stores only a hash |
| Reveal step | None | `revealAnswer()` verifies hash, then stores plaintext |
| `createBounty` params | `(title, rubric, deadline)` | `(title, rubric, deadline, revealWindow)` |
| `judgeAll` guard | after deadline | after `revealDeadline` |
| `getSubmission` return | `(submitter, answer)` | `(submitter, answer, revealed)` — answer is `""` until revealed |
| New view helpers | — | `hasCommitted()`, `getCommitment()` |
| Events | `AnswerSubmitted` | `CommitmentSubmitted`, `AnswerRevealed` |

---

## Commitment Hash Formula

```solidity
bytes32 commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
```

The `salt` is a random `bytes32` chosen by the participant and **never stored on-chain**. Without it an attacker could brute-force the hash. The `msg.sender` and `bountyId` bind the commitment so it cannot be replayed across addresses or bounties.

---

## Test Plan

Tests live in `hardhat/test/AIJudge.test.ts` and use Hardhat's `time` helper to simulate phase transitions.

### Happy path
- `submitCommitment` during commit phase → `CommitmentSubmitted` event emitted, `hasCommitted` returns true.
- `revealAnswer` after deadline with correct answer + salt → `AnswerRevealed` event, answer visible in `getSubmission`.
- Answer is **empty string** in `getSubmission` before reveal.

### Commit phase edge cases
- Duplicate commitment from same address → `"already committed"`.
- Commitment after `deadline` → `"commit phase closed"`.
- More than `MAX_SUBMISSIONS` commitments → `"too many commitments"`.

### Reveal phase edge cases
- Wrong answer with correct salt → `"commitment mismatch"`.
- Correct answer with wrong salt → `"commitment mismatch"`.
- Double reveal → `"already revealed"`.
- Reveal from address with no commitment → `"no commitment found"`.
- Reveal during commit phase (too early) → `"commit phase still open"`.
- Reveal after `revealDeadline` (too late) → `"reveal phase closed"`.

### Finalization edge cases
- `finalizeWinner` before `judgeAll` → `"not judged yet"`.
- `finalizeWinner` with index pointing to an unrevealed slot → `"winner did not reveal"`.

> **Note:** `judgeAll` requires a live Ritual node with the LLM precompile. Integration tests against the Ritual devnet are run separately; unit tests mock the boundary by testing all surrounding logic.

---

## Architecture Note

### What is stored on-chain
- Commitment hashes (public, but non-reversible without the salt).
- After reveal: plaintext answers and submitter addresses.
- AI review bytes and winner index after judging/finalization.

### What stays off-chain
- The answer and salt until the participant calls `revealAnswer`. Both are held locally by the participant (e.g. in the frontend or a text file).

### Where the LLM receives submissions
After the reveal deadline, **all revealed answers are readable on-chain**. The bounty owner reads them, constructs a single `llmInput` payload containing every answer together with the rubric, and calls `judgeAll`. Ritual's LLM precompile executes the inference inside a TEE and returns a single batch response — one LLM call for all answers, not one per answer.

### Trust model
- During the commit phase nobody (including the bounty owner) can see answers — only hashes.
- After the reveal deadline, answers become public, but the competition is already closed so copying is pointless.
- The LLM verdict is produced in Ritual's TEE; the owner then calls `finalizeWinner` with the index. A future improvement (Advanced Track) would have the contract parse the LLM output and auto-finalize, removing the last point of human trust.

---

## Reflection

**What should be public, what should stay hidden, and what should be decided by AI versus by a human in a bounty system?**

In a fair bounty system, the existence of a bounty — its title, rubric, reward, and deadline — must be fully public so that potential participants can make an informed decision to compete. Commitments should be public (they are hashes, so they reveal nothing) because their on-chain presence proves a submission was made before the deadline, preventing later disputes. The actual answers must stay hidden until the commit phase closes; exposing them early destroys the incentive to produce original work and turns the bounty into a copying race. Salt values should never appear on-chain, as they are the sole mechanism preventing hash pre-image attacks. The AI is well-suited to the objective, scalable part of judging: comparing many answers against a rubric in a single batch call is exactly the kind of repetitive reasoning that benefits from LLM consistency and eliminates evaluator fatigue. However, the final selection of a winner should remain with a human (the bounty owner) for now — the AI output is evidence and guidance, not a legally binding verdict, and edge cases like ties, disqualifications, or off-topic answers still benefit from human judgment. Over time, as LLM outputs become more reliable and on-chain verification of their correctness improves (e.g. through Ritual's TEE attestation), the human finalization step could be automated safely.
