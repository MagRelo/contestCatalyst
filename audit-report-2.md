https://bafkreihfmgvbtbmysempeer4m537f352e6lecuc37kcgdrazxibd2hvrjy.ipfs.community.bgipfs.com/

# Security Audit Report — ContestCatalyst

**Target**: `MagRelo/contestCatalyst` — `git rev-parse HEAD` = `6a93dc7adafa2984c7ede10f2eeaf19088ac8929`
**Scope**: `src/ContestController.sol`, `src/ContestFactory.sol`, `src/PrimaryContest.sol`, `src/SecondaryContest.sol`, `src/SecondaryPricing.sol` (1,039 LOC)
**Methodology**: Three-phase audit — Phase 0 (context: protocol map, access-control inventory, threat catalog, opus) → Phase 1 (breadth: 7 ethskills domain checklists — general, precision-math, erc20, erc1155, access-control, dos, defi-amm — opus) → Phase 2 (depth: 12 pashov attacker-mindset agents, run blind to Phase 1 findings, opus) → hybrid reconciliation with a Phase-0-driven coverage gate.
**Note on prior audit**: This repository contains a prior report (`audit-report.md`) from an earlier commit. Per this engagement's scope, every finding below comes from a fresh Phase 0 → Phase 1 → Phase 2 run against the current commit, independent of that prior report's conclusions.

## Reconciliation Summary

- **Overlap** (found by both phases independently): 6 of 8 substantive findings.
- **Phase-1-only**: 6 findings (oracle immutability, O(n²) duplicate-winner check, dust-burn-on-zero-payout, no slippage protection, unchecked int256 casts, blocklist/pause systemic risk, zero-deposit misconfiguration — 7 items, all Low/Info).
- **Phase-2-only**: 1 lead (referral-fee-call reentrancy/state-desync, Info).
- **Re-examined leads kept**: 7 (all Phase-1-only items above, confirmed against source on re-read). **Demoted**: 0.
- **Coverage**: 22 entrypoints in the Phase-0 inventory, 22 addressed (either by a finding below or an explicit "examined, no issue" — see Coverage Gate). 9 threat-catalog rows, 9 answered. **Coverage holes closed this pass: 0** (both phases already covered every entrypoint and catalog row independently).
- **Confidence floor**: all findings below have confidence ≥ 75 (multi-agent corroborated, source-verified, and cross-checked against the repo's own test suite where cited). No sub-50-confidence leads survived to reporting — the "Leads" subsections under each severity summarize what was investigated and not promoted, for transparency.

**The standout result of this run**: finding P2-1 (secondary-market fund-stranding) was independently raised by **10 of 19 total hunting agents** across both phases via completely different attack lenses (checklist-driven, execution-trace, invariant-violation, paired-function-asymmetry, boundary-condition, numerical-seam, flow-gap, and periphery-library analysis), and finding P2-2 (`cancelExpired` settlement race) was flagged by **all 19** agents in some form. Both are corroborated against the repository's own Foundry test suite (see each finding).

---

## Access-Control Inventory

Exactly **one** privileged role exists: `oracle`, declared `address public immutable oracle` (`ContestController.sol:34`), set once in the constructor (`:141`, validated non-zero `:132`), with **no transfer, renounce, or two-step handoff** — see finding L-1. `PrimaryContest.sol`, `SecondaryContest.sol`, and `SecondaryPricing.sol` are pure/internal libraries with no external entrypoints of their own.

| Function                                                           | Guard                                            | Caller                       | Moves value?                                                                                                |
| ------------------------------------------------------------------ | ------------------------------------------------ | ---------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `addPrimaryPosition`                                               | `nonReentrant`; optional merkle proof            | any address                  | pulls deposit                                                                                               |
| `removePrimaryPosition`                                            | `nonReentrant`; caller owns entry                | entry owner                  | refunds deposit                                                                                             |
| `claimPrimaryPayout`                                               | `nonReentrant`; caller owns entry                | entry owner                  | pays claimant                                                                                               |
| `addSecondaryPosition`                                             | `nonReentrant`; optional merkle proof            | any address                  | pulls payment, mints ERC1155                                                                                |
| `removeSecondaryPosition`                                          | `nonReentrant`; token holder, OPEN/CANCELLED     | any holder                   | pays seller                                                                                                 |
| `claimSecondaryPayout`                                             | `nonReentrant`; winning-entry holder, SETTLED    | any holder                   | pays claimant                                                                                               |
| `activateContest` / `lockContest`                                  | `onlyOracle`                                     | oracle                       | no                                                                                                          |
| `settleContest`                                                    | `onlyOracle` + `nonReentrant`                    | oracle                       | indirect (referral self-call)                                                                               |
| `distributeReferralFee`                                            | **self-call only** (`msg.sender==address(this)`) | self                         | fans out referral fee                                                                                       |
| `cancelContest`                                                    | `onlyOracle`                                     | oracle                       | no                                                                                                          |
| `closeContest`                                                     | `onlyOracle` + `nonReentrant`                    | oracle                       | sweeps full balance to oracle                                                                               |
| `setPrimaryMerkleRoot` / `setSecondaryMerkleRoot`                  | `onlyOracle`                                     | oracle                       | no                                                                                                          |
| **`cancelExpired`**                                                | **none** — time + state only                     | **any address**, post-expiry | no                                                                                                          |
| `pushPrimaryPayouts`                                               | `onlyOracle` + `nonReentrant`                    | oracle                       | pays owners (batch, not isolated)                                                                           |
| `pushSecondaryPayouts`                                             | `onlyOracle` + `nonReentrant`                    | oracle                       | pays holders (batch, per-recipient isolated)                                                                |
| `paySecondaryClaimExternal`                                        | **self-call only**                               | self                         | pays one holder                                                                                             |
| `setApprovalForAll` / `safeTransferFrom` / `safeBatchTransferFrom` | always `revert`                                  | n/a                          | no (shares are non-transferable by design)                                                                  |
| `ContestFactory.createContest`                                     | **none**                                         | any address                  | no — deploys a new controller and **freely picks its own `oracle`**, including itself (see P2-1 escalation) |

---

## Threat Model

| Actor                                                                | Reaches                                                       | Could gain                                              | Addressed by                                                                                                      |
| -------------------------------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Any address (merkle root unset)                                      | `addPrimaryPosition`/`addSecondaryPosition`                   | unrestricted participation                              | Invariant holds — registry/supply bookkeeping is correct regardless of caller                                     |
| Secondary buyer that is a contract                                   | `onERC1155Received` callback mid-buy                          | control mid-transaction                                 | Invariant holds — `nonReentrant` blocks all guarded re-entry; verified by 4+ agents                               |
| Oracle (trusted role)                                                | `settleContest`                                               | picks arbitrary winners within payout-sum constraint    | Invariant holds / documented trust assumption — out of scope per prior repo commit "Document contest trust model" |
| Oracle                                                               | `closeContest`                                                | sweeps 100% of remaining balance post-expiry            | **P2-3** (Medium)                                                                                                 |
| Any address, post-expiry                                             | `cancelExpired`                                               | permanently blocks settlement                           | **P2-2** (High)                                                                                                   |
| Referral graph / reward calculator (external, black box)             | `distributeReferralFee` internals                             | up to the bounded referral fee                          | Invariant holds — capped at 10 recipients, `Σamounts≤fee` enforced, try/catch-contained                           |
| Non-standard `paymentToken` (fee-on-transfer/rebasing/blocklist)     | every transfer site                                           | accounting drift vs. real custody                       | **L-2** (Medium)                                                                                                  |
| Any secondary seller, across all entries sharing one pooled balance  | sell-back/claim `balanceOf(this)` clamps                      | first-mover advantage under balance drift               | **L-2** (folded in — same root cause)                                                                             |
| Oracle-supplied batch (`pushPrimaryPayouts`)                         | one reverting recipient                                       | blocks the whole batch                                  | **L-3** (Low)                                                                                                     |
| Primary entry owner (any address, including a self-appointed oracle) | `removePrimaryPosition` while entry has live secondary supply | strands/steals secondary buyers' backed liquidity       | **P2-1** (High, escalating to a deterministic rug under a self-appointed oracle)                                  |
| Early vs. late secondary buyer                                       | curve-priced buy vs. pro-rata-priced exit                     | principal transfer between user classes on cancellation | **P2-4** (Medium)                                                                                                 |

**Coverage gate**: 22/22 entrypoints addressed (finding or "examined, no issue"); 9/9 threat rows answered; **0 coverage holes** — both phases independently reached full coverage.

---

## Findings

### High

#### [P2-1] `removePrimaryPosition` orphans a live entry's secondary market — permanently strands (or, under a self-appointed oracle, steals) secondary buyers' funds

**Severity**: High (escalates toward Critical under the self-appointed-oracle path described below)
**Confidence**: 95 — independently found by **10 of 19** hunting agents (Phase 1: `general-1`, `erc1155-1`; Phase 2: 8 of 12 agents via execution-trace, invariant, periphery, first-principles, asymmetry, boundary, numerical-gap, and flow-gap lenses) and confirmed against the repository's own test suite.
**Location**: `removePrimaryPosition()` `ContestController.sol:171-183`; `PrimaryContest.processRemovePrimaryPosition()` `PrimaryContest.sol:82-92`; gate in `SecondaryContest.validateRemoveSecondaryPosition()` `SecondaryContest.sol:46-60`

```solidity
// ContestController.sol:171-183
function removePrimaryPosition(uint256 entryId) external nonReentrant {
    PrimaryContest.validateRemovePrimaryPosition(entryOwner, entryId, msg.sender, uint8(state));

    (uint256 refundAmount,) = PrimaryContest.processRemovePrimaryPosition(entryOwner, entryId, primaryDepositAmount);
    _removeActiveEntry(entryId);
    ...
```

```solidity
// PrimaryContest.sol:82-92
function processRemovePrimaryPosition(
    mapping(uint256 => address) storage entryOwner,
    uint256 entryId,
    uint256 primaryDepositAmount
) internal returns (uint256 refundAmount, uint256 primaryContribution) {
    address owner = entryOwner[entryId];
    entryOwner[entryId] = address(0);          // <-- zeroed unconditionally
    ...
```

```solidity
// SecondaryContest.sol:46-60
function validateRemoveSecondaryPosition(...) internal view {
    require(currentState == 0 || currentState == 4, "Cannot withdraw - competition started or settled");
    require(entryOwner[entryId] != address(0), "Entry does not exist");   // <-- line 57, the trap
    require(tokenAmount > 0, "Amount must be > 0");
    require(balance >= tokenAmount, "Insufficient balance");
}
```

**Description**: `removePrimaryPosition` is callable while `state` is OPEN(0) or CANCELLED(4), and unconditionally zeroes `entryOwner[entryId]` — with **no check** of `netPosition[entryId]` (outstanding ERC1155 supply) or `secondaryLiquidityPerEntry[entryId]` (backed liquidity, real ERC20 tokens already custodied). Both secondary exits — `removeSecondaryPosition` (line 57 above) and `claimSecondaryPayout` (an identical `entryOwner != 0` check) — require the owner slot to still be populated. Secondary positions can only be bought while ACTIVE(1) (`SecondaryContest.sol` buy validator), so the only reachable window where a live secondary position and a legal primary removal coexist is CANCELLED — precisely the state cancellation is meant to unlock for _both_ sides' refunds. Once the primary owner removes first, every secondary holder on that entry is permanently locked out of both exits (claim requires SETTLED, which CANCELLED never reaches), and their liquidity sits in the contract until `closeContest` sweeps the whole balance to `oracle`.

**Proof of Concept — reproduced exactly by the repo's own test**: `test/ContestController.t.sol:1085-1100`, `test_removeSecondaryPosition_EntryDoesNotExist`:

```solidity
function test_removeSecondaryPosition_EntryDoesNotExist() public {
    _createPrimaryEntry(user1, ENTRY_1);
    _createSecondaryPosition(user2, ENTRY_1, PURCHASE_INCREMENT);

    vm.prank(oracle);
    contest.cancelContest();

    vm.prank(user1);
    contest.removePrimaryPosition(ENTRY_1);

    uint256 tokens = contest.balanceOf(user2, ENTRY_1);

    vm.prank(user2);
    vm.expectRevert("Entry does not exist");
    contest.removeSecondaryPosition(ENTRY_1, tokens);
}
```

This test proves the revert is reproducible exactly as described, but makes no assertion that user2's `PURCHASE_INCREMENT` liquidity is recoverable anywhere else — it isn't. There is no re-add path for `entryId` (re-registration requires OPEN state), so user2's funds are captured only by `closeContest`'s indiscriminate full-balance sweep to `oracle`.

**Escalation — a self-appointed oracle can make this a deterministic rug, not accidental griefing**: `ContestFactory.createContest()` (`ContestFactory.sol:16-46`) takes `oracle` as a caller-supplied parameter with no restriction that it differ from the caller or from any entry owner:

```solidity
// ContestFactory.sol:16-27
function createContest(
    address paymentToken,
    address oracle,          // <-- caller-chosen, unrestricted
    ...
) external returns (address) {
    ContestController contest = new ContestController(paymentToken, oracle, ...);
```

An attacker can: (1) deploy a `ContestController` naming themselves `oracle`; (2) register themselves as the sole primary entry owner; (3) `activateContest()` (self, as oracle) to open secondary buying and let victims buy shares on the entry; (4) `cancelContest()` (self, as oracle); (5) `removePrimaryPosition()` (self, as entry owner) — refunding their own deposit and, per this finding, permanently orphaning every secondary buyer's liquidity; (6) after expiry, `closeContest()` (self, as oracle) sweeps the orphaned liquidity to themselves. Every step is a normal, code-permitted call — the attacker controls every precondition, so this is not a race that depends on unlucky ordering but a deterministic theft primitive available to any deployer of the (permissionless) `ContestFactory`.

**Recommendation**: In `removePrimaryPosition` (or `PrimaryContest.validateRemovePrimaryPosition`), require `netPosition[entryId] == 0 && secondaryLiquidityPerEntry[entryId] == 0` before permitting removal. Additionally/alternatively, drop the `entryOwner[entryId] != address(0)` requirement from `validateRemoveSecondaryPosition` and `validateClaimSecondaryPayout` so a holder's exit depends only on their own share balance and the entry's tracked liquidity — never on whether the primary registrant is still present.

---

#### [P2-2] Permissionless `cancelExpired` can permanently pre-empt `settleContest`

**Severity**: High
**Confidence**: 95 — flagged by **19 of 19** hunting agents in some form (Phase 1: `access-1`, `dos-4`, `general-5`; Phase 2: FINDING from 3 agents, LEAD from the remaining 9). Confirmed against the repo's own test suite.
**Location**: `cancelExpired()` `ContestController.sol:468-473` vs. `settleContest()` `ContestController.sol:298-306` vs. `cancelContest()` `ContestController.sol:434-438`

```solidity
// ContestController.sol:468-473
function cancelExpired() external {
    require(block.timestamp >= expiryTimestamp, "Not expired");
    require(state != ContestState.SETTLED && state != ContestState.CLOSED, "Already settled");
    state = ContestState.CANCELLED;
    emit ContestCancelled();
}
```

```solidity
// ContestController.sol:298-306
function settleContest(uint256[] calldata winningEntries, uint256[] calldata payoutBps)
    external
    onlyOracle
    nonReentrant
{
    require(state == ContestState.LOCKED, "Contest not locked");   // no expiry check at all
    ...
```

**Description**: `settleContest` has no expiry precondition — the intended flow is lock, then settle at or after `expiryTimestamp` once the real-world outcome is known. But `cancelExpired` is permissionless and accepts LOCKED(2) as a valid starting state (it only excludes SETTLED/CLOSED). Once expiry passes on a LOCKED contest, **any address** — rationally, a participant anticipating a loss — can call `cancelExpired()` before the oracle's `settleContest()` lands, permanently forcing `state = CANCELLED`. Lifecycle transitions are forward-only (`activateContest` requires OPEN, `lockContest` requires ACTIVE) and `settleContest` demands LOCKED — so settlement is permanently and irreversibly foreclosed. The contest falls back to full refunds via `removePrimaryPosition`/`removeSecondaryPosition`, both CANCELLED-gated.

**Proof of Concept**: Contest LOCKED, `block.timestamp >= expiryTimestamp`, oracle about to call `settleContest` naming a known winning entry. The owner of a losing entry calls `cancelExpired()` first → `state = CANCELLED`. `settleContest` now reverts `"Contest not locked"` forever — there is no path back to LOCKED. The losing entry's owner then calls `removePrimaryPosition` and recovers the full deposit they would otherwise have forfeited to the winner; the intended winner never receives the pooled prize. No token leaves the contract incorrectly (every participant is refunded), which is why this is rated High rather than Critical — but the protocol's core prize-distribution function is permanently and unilaterally destroyed at the cost of one ~30k-gas transaction, and the repo's own tests corroborate the design gap: `test_E2E_CancelExpired_thenRefunds` (`test/ContestLifecycleE2E.t.sol:181`) warps past expiry before cancelling, while every `test_E2E_Settled_*` test (e.g. `:75`, `:109`, `:217`) settles **without** ever warping past expiry first — confirming the implicit design assumption "settle before expiry" is never enforced in code.

**Recommendation**: Exclude LOCKED from `cancelExpired`'s eligible states (`require(state == ContestState.OPEN || state == ContestState.ACTIVE, "Settlement pending")`), preserving the permissionless safety valve for pre-lock contests while giving the oracle an exclusive post-lock settlement window. Alternatively, add a grace period after expiry before `cancelExpired` becomes callable on a LOCKED contest, or require `settleContest` to run strictly before `expiryTimestamp`.

---

### Medium

#### [P2-3] `closeContest` has no state or claims precondition — a tested, intended "residual sweep" with no bound on the swept amount

**Severity**: Medium
**Confidence**: 90 — LEAD from 8 of 12 Phase 2 agents, corroborates Phase 1's `access-2`. Confirmed against the repo's own test suite, which changes the framing from "oversight" to "intended mechanism with an unbounded blast radius."
**Location**: `closeContest()` `ContestController.sol:440-456`

```solidity
// ContestController.sol:440-456
function closeContest() external onlyOracle nonReentrant {
    require(block.timestamp >= expiryTimestamp, "Expiry not reached");

    uint256 remaining = IERC20Balance(paymentToken).balanceOf(address(this));
    if (remaining > 0) {
        primaryPrizePool = 0;
        for (uint256 i = 0; i < entries.length; i++) {
            uint256 eid = entries[i];
            secondaryLiquidityPerEntry[eid] = 0;
            secondaryPrimarySubsidyPerEntry[eid] = 0;
        }
        state = ContestState.CLOSED;
        SafeTransferLib.safeTransfer(ERC20(paymentToken), oracle, remaining);
        emit ContestClosed();
    }
}
```

**Description**: Guarded only by `onlyOracle` and `block.timestamp >= expiryTimestamp` — no `state` precondition at all. If the real ERC20 balance is non-zero, it zeroes every pool/liquidity bucket and sweeps the **entire** balance to `oracle`, callable from any pre-CLOSED state, including a contest that never activated (deposits sitting unclaimed) or a SETTLED contest whose winners haven't yet called `claimPrimaryPayout`/`claimSecondaryPayout`.

**Proof — confirmed as intended design by the repo's own test**: `test/ContestLifecycleE2E.t.sol:203-214`, `test_E2E_CloseContest_routesResidualToOracle`:

```solidity
function test_E2E_CloseContest_routesResidualToOracle() public {
    _primary(contest, u1, ENTRY_1);
    uint256 oracleBefore = paymentToken.balanceOf(oracle);

    vm.warp(block.timestamp + EXPIRY_OFFSET + 1);
    vm.prank(oracle);
    contest.closeContest();

    assertEq(uint8(contest.state()), uint8(5));
    assertGt(paymentToken.balanceOf(oracle), oracleBefore);
    ...
}
```

This test deposits a single primary entry and **never activates, locks, settles, or cancels the contest** — it warps past expiry and calls `closeContest()` directly from OPEN, asserting the oracle's balance increases. This confirms the sweep-to-oracle mechanism is an intentional, tested design choice (the team's own framing is "residual" routing), not an oversight. However, neither the code nor this test bounds the swept amount to genuine dust — the mechanism is identical whether the amount is 1 wei of rounding leftover or the full pool of a SETTLED contest whose winners haven't claimed yet.

**Recommendation**: Bound the sweep to genuine residual dust (e.g., a small absolute or relative threshold), or require `state == SETTLED || state == CANCELLED` with all tracked payouts/liquidity already claimed/zeroed before permitting the sweep, or add a claims grace period. At minimum, document clearly (in addition to the code comment) that any un-claimed/un-refunded balance at expiry is forfeit to the oracle, so integrators and users are unambiguously on notice.

---

#### [P2-4] Secondary sell-back/claim redeems at flat pool-average price while buys are priced on the convex curve

**Severity**: Medium
**Confidence**: 85 — FINDING from 1 Phase 2 agent with full numeric proof, LEAD from 2 more; corroborates Phase 1's `amm-1`. One Phase 2 agent located the `SecondaryPricing.sol` design comment stating "early bettors get better prices" is an _intended_ curve property — this finding is best read as the linear-exit mechanism amplifying an intended property beyond its likely intended scope (pricing fairness during the ACTIVE market), rather than a pure oversight.
**Location**: `addSecondaryPosition()` `ContestController.sol:202-228` (curve-priced mint) vs. `removeSecondaryPosition()` `ContestController.sol:242` (`cashOut = tokenAmount * liquidity / supply`) and `_paySecondaryClaim()` `ContestController.sol:544` (same pro-rata formula)

**Description**: Buys are priced on the rising quadratic curve in `SecondaryPricing.sol` (_"price = BASE_PRICE + COEFFICIENT \* shares^2 ... Early bettors get better prices (lower supply = lower price)"_ — the file's own header comment), so later/larger buyers pay strictly more per share than earlier/smaller ones for the same entry. Both redemption paths — cancellation sell-back and post-settlement claim — instead pay flat pool-average `liquidity/supply`, independent of what a given holder's own shares cost to mint. This transfers principal from later (higher-priced) buyers to earlier (lower-priced) buyers whenever a contest is cancelled after multiple buys at divergent curve points. The transfer is exactly zero-sum between users (no protocol insolvency, `cashOut` is always bounded by the entry's own tracked liquidity), but is a materially unfair outcome for a mechanism whose stated purpose in the CANCELLED case is to return participants' money.

**Proof of Concept** (verified numerically; curve constants `BASE_PRICE=1e6`, `COEFFICIENT=15`, 18-decimal payment token, `PRICE_PRECISION=1e6`):

1. Alice buys with $50 on an empty entry → curve gives her ≈49.4 tokens; `secondaryLiquidityPerEntry=50`, `netPosition=49.4`.
2. Bob buys with $1000 → curve prices him marginally from Alice's post-buy supply, giving only ≈434.4 tokens; `liquidity=1050`, `supply=483.8`.
3. Contest is cancelled. Pool pro-rata price = `1050/483.8 = 2.170`/token.
4. Alice sells her 49.4 tokens: `cashOut = 49.4 × 1050 / 483.8 = $107.2`. She deposited $50 → **profit $57.2**.
5. Bob sells his 434.4 tokens: remaining liquidity/supply gives him **$942.8**. He deposited $1000 → **loss $57.2** — an under-refund on what is nominally a cancellation refund.

**Recommendation**: For the cancellation-refund case specifically, refund each holder their own tracked `secondaryDepositedPerEntry` principal (already maintained on-chain at `ContestController.sol:224`/`251-252`, currently used only for frontend display — `secondaryDepositedPerEntry` doc comment: "used by frontend UI... not used for pricing") rather than a pro-rata pool share. This is the minimal fix and requires no curve-inversion math. Alternatively, make redemption the mathematical inverse of the mint curve so buy and sell are fully path-consistent in both the cancellation and settlement cases.

---

### Low

#### [L-1] `oracle` is immutable with no transfer, renounce, or two-step handoff

**Severity**: Low **Confidence**: 90 **Origin**: Phase 1 `access-3`
**Location**: `oracle` `ContestController.sol:34`, set once `:141`, `onlyOracle` `:115-118`
Sole privileged role, set once at construction with no rotation path. Key loss/compromise permanently disables every oracle-gated function. Mitigated to Low (not High) because the permissionless `cancelExpired` (P2-2) means participant principal always remains recoverable post-expiry even with total key loss — the residual cost is "contest can never be settled with a prize, only refunded."
**Recommendation**: Consider a two-step oracle handoff for future versions if key-rotation-before-suspected-compromise is desired; otherwise document the trust assumption explicitly.

#### [L-2] Fee-on-transfer / deflationary / rebasing `paymentToken` breaks add-side accounting and can hard-revert primary refunds/claims

**Severity**: Low (escalates to Medium if such a token is ever configured — see note) **Confidence**: 85 **Origin**: Phase 1 `erc20-1`/`general-2`/`amm-3`/`erc20-2`; corroborated as a lead by 4 Phase 2 agents (folded together with the "shared-custody first-mover" lead — same root cause)
**Location**: `addPrimaryPosition()` `ContestController.sol:163-168`, `addSecondaryPosition()` `:220-226`, `removePrimaryPosition()` `:182`, `claimPrimaryPayout()` `:198`, `pushPrimaryPayouts()` `:505`
Every deposit site credits accounting with the _nominal_ parameter amount before pulling via `safeTransferFrom`, never measuring the actual balance received. If `paymentToken` charges a transfer fee, is deflationary, or rebases downward, real custody permanently falls short of tracked liabilities. Secondary payout paths clamp to `balanceOf(this)` and silently underpay the last claimant; the primary refund/claim/push-payout transfers are **unclamped** and will hard-revert once real balance dips below the nominal amount owed — a DoS for whichever primary depositor exits last. All Phase 2 agents who investigated confirmed no drift is constructible under a _standard_ ERC20 — this is a configuration-dependent risk, not an unconditional exploit, hence Low as the base rating.
**Recommendation**: Measure `balanceOf(this)` before/after each pull and credit the actual delta received; clamp the primary refund/claim/push transfers the same way the secondary paths already are.

#### [L-3] `pushPrimaryPayouts` batch is not per-recipient isolated

**Severity**: Low **Confidence**: 90 **Origin**: Phase 1 `general-4`/`erc20-3`/`dos-3` (3 agents) + Phase 2 leads from 7 of 12 agents — 10 of 19 total agents flagged this
**Location**: `pushPrimaryPayouts()` `ContestController.sol:482-508`, un-isolated transfer at `:505`
Unlike `pushSecondaryPayouts` (isolates each recipient via `try this.paySecondaryClaimExternal(...) {} catch {}` at `:526`), `pushPrimaryPayouts` transfers directly with no wrapper. One blocklisted/reverting `owner` in the oracle-supplied batch reverts the entire call. Mitigated: every winner also has the independent `claimPrimaryPayout` pull path, and the oracle controls the batch composition.
**Recommendation**: Mirror the secondary path — wrap each recipient's transfer in a self-call `try/catch` so one bad recipient is skipped rather than blocking the batch.

#### [L-4] `settleContest`'s O(n²) duplicate-winner check is oracle-self-inflicted gas cost

**Severity**: Low **Confidence**: 85 **Origin**: Phase 1 `dos-2`
**Location**: `settleContest()` `ContestController.sol:314-317`
Nested loop over `winningEntries` (up to `entries.length`, capped at `MAX_ENTRIES=500`) is O(w²). Worst case (w=500) combined with mandatory `entries[]` loops totals ≈23-25M gas — under a ~30M block limit, so it executes, but wastefully. `w` is entirely oracle-chosen, so no unprivileged party can force this cost.
**Recommendation**: Replace with an O(n) seen-set (transient mapping/bitmap on `entryId`) or require sorted+strictly-increasing `winningEntries`.

#### [L-5] Secondary sell/claim burns shares even when pro-rata proceeds round to zero

**Severity**: Low **Confidence**: 80 **Origin**: Phase 1 `precision-2`
**Location**: `removeSecondaryPosition()` `ContestController.sol:242-266`, `_paySecondaryClaim()` `:544-566`
For low-decimal payment tokens (e.g. USDC), a redemption below `supply/liquidity` share-wei rounds `cashOut`/`payout` to 0, but the code still burns the shares. Self-inflicted dust loss only, no third-party impact.
**Recommendation**: `require(cashOut > 0)` in `removeSecondaryPosition` so dust sellers revert rather than burn for nothing.

#### [L-6] No slippage/minimum-output protection on secondary buy/sell

**Severity**: Low **Confidence**: 80 **Origin**: Phase 1 `amm-2`
**Location**: `addSecondaryPosition()` `ContestController.sol:202-228`, `removeSecondaryPosition()` `:231-267`
No `minTokensOut`/`minCashOut` parameters. An atomic single-block sandwich is not possible (buys require ACTIVE, sells require OPEN/CANCELLED — states never overlap), but adverse multi-buy ordering within ACTIVE can still shift the price a victim receives.
**Recommendation**: Add caller-supplied `minTokensOut`/`minCashOut` reverting if unmet.

#### [L-7] Unchecked `int256(...)` narrowing casts on token amounts

**Severity**: Low **Confidence**: 75 **Origin**: Phase 1 `general-3`
**Location**: `SecondaryContest.sol:84,95`; `ContestController.sol:552`
`netPosition[entryId] += int256(participantTokensReceived)` etc. cast uint256→int256 without `SafeCast`. Not realistically reachable (requires an astronomical single-buy share amount); latent best-practice gap only.
**Recommendation**: Use `SafeCast.toInt256`.

#### [L-8] Blocklist/pause of `paymentToken` or the contract itself freezes all funds

**Severity**: Low **Confidence**: 80 **Origin**: Phase 1 `erc20-4`
**Location**: whole-contract custody; all transfer sites
If `paymentToken` is a centralized-stablecoin-style token and the contract address is blocklisted, or transfers are globally paused, every outbound transfer reverts — all funds frozen. Inherent custodial-token risk, deployer-config-dependent, not a code defect.
**Recommendation**: Document the token-issuer trust assumption.

#### [L-9] Zero `primaryDepositAmount` + zero-amount-reverting token bricks the contest

**Severity**: Low **Confidence**: 80 **Origin**: Phase 1 `erc20-5`
**Location**: constructor `ContestController.sol:142` (no `>0` check), `addPrimaryPosition()` `:168`
Constructor doesn't reject `primaryDepositAmount==0`. Combined with a zero-amount-reverting token, the contest could never activate. Pure liveness/misconfiguration, no funds at risk since none were ever deposited.
**Recommendation**: `require(_primaryDepositAmount > 0)` in the constructor.

---

### Info

#### [I-1] Referral-fee self-call precedes the SETTLED state write, creating a narrow reentrancy window with no fund impact

**Severity**: Info **Confidence**: 60 (Phase-2-only lead, not independently corroborated) **Origin**: Phase 2 agent 2 (access-control)
**Location**: `settleContest()` `ContestController.sol:342-346` (referral try/catch) vs. `:349` (state write to SETTLED)
`distributeReferralFee`'s external graph/calculator calls execute while `state` is still LOCKED (the write to SETTLED happens after the try/catch block). `cancelExpired` is not `nonReentrant`-guarded. A hostile `referralGraph` could theoretically re-enter `cancelExpired` mid-settlement, but `state` is unconditionally overwritten to SETTLED afterward regardless — the only demonstrated residual effect is a spurious `ContestCancelled` event inside a transaction that finalizes as SETTLED (an off-chain indexer desync), not fund corruption. No concrete state corruption was demonstrated by the reporting agent; kept at Info.
**Recommendation**: Consider moving the `state = ContestState.SETTLED` write before the referral try/catch block for defense-in-depth, though no exploit path currently depends on the ordering.

#### [I-2] Precision/rounding characteristics of `SecondaryPricing` (dust-level, all favor the pool)

**Severity**: Info **Confidence**: 85 **Origin**: Phase 1 `precision-1`,`precision-3`,`precision-4`; Phase 2 corroborated as clean
The deliberate `shares/1e9` truncation in `calculatePrice`, the Simpson's-rule integrated-cost rounding, and `toShareUnits`'s truncation for >18-decimal tokens are all bounded to relative errors far below 1 wei of practical impact, and every rounding direction favors the pool/protocol over the user (verified independently by 2+ agents in each phase). No action required.

#### [I-3] `SafeTransferLib` no-code-address semantics are only incidentally guarded by the constructor's `decimals()` call; `paymentTokenDecimals` is cached once and never re-read

**Severity**: Info **Confidence**: 80 **Origin**: Phase 1 `erc20-6`,`erc20-7`
Solmate's `SafeTransferLib` would treat a no-code `paymentToken` as a silent-success no-op, but the constructor's `ERC20(_paymentToken).decimals()` call reverts for any address without code, incidentally preventing this configuration. `paymentTokenDecimals` is immutable after construction; an upgradeable-proxy token that later changes its `decimals()` would silently mis-price secondary buys. No known exploit path; noted for completeness.

---

## What Was Checked and Found Sound

Independently verified by multiple agents across both phases, listed here per the coverage gate so the client knows these were examined and not merely skipped:

- **Settlement value-conservation**: `netPrimary + netSecondary + referralFee <= totalGross` holds under integer flooring in every branch, including the zero-supply winner redistribution.
- **ERC1155 supply integrity**: `netPosition[entryId]` stays exactly equal to the sum of that entry's holder balances across every mint/burn path.
- **Reentrancy**: every value-moving entrypoint is `nonReentrant`; the one caller-reachable callback (`onERC1155Received` on secondary buy) fires last, after all state is written, and cannot reach any other guarded function.
- **Referral-fee containment**: `distributeReferralFee` is bounded (chain capped at 10 via the `MAX_REFERRAL_PAYOUT_LEVELS` assembly truncation, `Σamounts≤fee` enforced) and fully try/catch-isolated from `settleContest` — any revert falls back to paying the oracle, settlement always completes.
- **`SecondaryPricing` curve math**: Simpson's rule is exact for the underlying cubic integral; the binary search always rounds in the protocol's favor (never over-mints).
- **`activateContest`/`lockContest`/`setPrimaryMerkleRoot`/`setSecondaryMerkleRoot`/`pushSecondaryPayouts`/`paySecondaryClaimExternal`**: straightforward, correctly guarded, no findings.
- **`ContestFactory`**: retains no post-deploy privilege over what it deploys (aside from the `oracle`-choice escalation folded into P2-1).

## Severity Legend

- **Critical**: direct loss of funds by a third party, no preconditions.
- **High**: loss of funds requiring specific conditions, or permanent DoS of a core function.
- **Medium**: degraded behavior, trust-model violation, incorrect accounting, or owner-only fund loss.
- **Low**: best-practice violation, latent bug, or confusing behavior without direct fund risk.
- **Info**: informational, no security impact.

## Summary Table

| ID   | Title                                                                | Severity | Confidence |
| ---- | -------------------------------------------------------------------- | -------- | ---------- |
| P2-1 | `removePrimaryPosition` strands/steals secondary-market funds        | High     | 95         |
| P2-2 | Permissionless `cancelExpired` permanently blocks `settleContest`    | High     | 95         |
| P2-3 | `closeContest` unbounded post-expiry sweep                           | Medium   | 90         |
| P2-4 | Secondary redemption pricing asymmetry (curve buy vs. pro-rata exit) | Medium   | 85         |
| L-1  | Oracle immutable, no handoff                                         | Low      | 90         |
| L-2  | Fee-on-transfer/rebasing token accounting drift                      | Low      | 85         |
| L-3  | `pushPrimaryPayouts` batch not isolated                              | Low      | 90         |
| L-4  | O(n²) duplicate-winner check                                         | Low      | 85         |
| L-5  | Dust burn on zero payout                                             | Low      | 80         |
| L-6  | No slippage protection                                               | Low      | 80         |
| L-7  | Unchecked int256 casts                                               | Low      | 75         |
| L-8  | Blocklist/pause systemic freeze risk                                 | Low      | 80         |
| L-9  | Zero-deposit misconfiguration                                        | Low      | 80         |
| I-1  | Referral-call reentrancy/state-desync window                         | Info     | 60         |
| I-2  | SecondaryPricing rounding characteristics                            | Info     | 85         |
| I-3  | SafeTransferLib/decimals caching notes                               | Info     | 80         |

**2 High, 2 Medium, 9 Low, 3 Info.**
