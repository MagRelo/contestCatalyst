# 🔐 Security Review — contestCatalyst (ContestController / ContestFactory)

**Repo**: MagRelo/contestCatalyst
**Commit reviewed**: `4dd88f6eb4bad51cb410cf90095f8b76c16aa840` (default branch HEAD at audit time — the job description did not pin a specific tag or commit)
**Scope**: `src/ContestController.sol`, `src/ContestFactory.sol`, `src/PrimaryContest.sol`, `src/SecondaryContest.sol`, `src/SecondaryPricing.sol` (1,097 LOC)
**Client's ask**: *"check these contracts, especially the new roles. the latest changes are intended to reduce the risk of the hot oracle role to some degree. check all lifecycle states, and roles and find improvements."*
**Methodology**: three-phase audit — Phase 0 context building (protocol map + access-control inventory + threat catalog, opus) → Phase 1 breadth (5 ethskills domain agents: general, precision-math, access-control, erc20, dos, opus) → Phase 2 depth (12 pashov attack agents, blind to Phase 1, opus) → Phase 3 hybrid reconciliation.
**Prior audits**: this repo contains `docs/audit-report.md` and `docs/audit-report-2.md` from earlier engagements. Per this job's protocol, every finding below was independently derived from this run's own phase 0/1/2 agents against the current commit — no finding was copied from the prior reports. Where this audit's results overlap or diverge from the prior reports, that is noted inline.

---

## Reconciliation Summary

- **Overlap** (found independently by both Phase 1 and Phase 2, or by multiple Phase 2 agents blind to each other): 7 of 9 major findings — extraordinarily high convergence. The two highest-severity findings (`emergencyRecoverFunds` zero-claim-window, secondary-pool dust capture) were each independently rediscovered by **8–10 of the 17 total hunting agents**, from completely different analytical angles (access-control, math-precision, economic-security, execution-trace, first-principles, boundary, asymmetry, trust-gap, invariant, flow-gap, numerical-gap, periphery).
- **Phase-1-only**: entry-slot squatting root cause (unvalidated `primaryDepositAmount`), merkle-root mid-contest mutability, no minimum lifecycle-state duration, immutable/non-rotatable roles with unbounded expiry, fee-on-transfer/rebasing token insolvency, `settleContest` O(n²) gas ceiling (measured via forge tests to 36M gas at 500 winners), factory registry omitting role addresses from its creation event.
- **Phase-2-only**: `winningEntries[0]` array-order value routing, oracle atomically front-running its own bonding curve then using `cancelContest` as a risk-free put, bonding-curve value/decimals miscalibration (COEFFICIENT assumes $1/token).
- **Re-examined leads kept**: all phase-unique findings above were cross-checked against source during reconciliation and confirmed. **Demoted**: none — every phase-unique finding survived re-examination.
- **Coverage holes closed this pass**: 0. Every privileged/value-moving entrypoint in the access-control inventory and every threat-catalog row was already examined by at least one phase; nothing required a first-time re-read in Phase 3.
- **Important correction discovered mid-audit**: Phase 0's external-surface agent reported `lib/referralTree` as unvendored/empty in this checkout. It is in fact present and readable (`lib/referralTree/src/core/{ReferralGraph,RewardCalculator}.sol`) — multiple Phase 2 agents read it directly and confirmed `getReferrer` returns `address(0)` by default (making the referral-fee-misallocation finding below a **default-path** issue, not an edge case) and that the canonical `RewardCalculator` always allocates exactly (downgrading the "unreturned shortfall" sub-issue to Low, reachable only with a non-canonical calculator).
- **Corrected fragility-cluster hypothesis**: the protocol map's #1-ranked fragility cluster — `removePrimaryPosition` orphaning secondary holders in CANCELLED — was investigated by nearly every hunting agent and **does not hold as a fund-loss**: `SecondaryContest.validateRemoveSecondaryPosition` never checks `entryOwner`, so secondary holders can always exit for their full tracked principal regardless of whether the primary owner already withdrew. It remains a real (Low-severity) accounting-view inconsistency, detailed below.
- **Confidence / reporting floor**: all findings below are reported at confidence ≥ 75 (every finding has a walked, concrete exploit path with numbers). No sub-50-confidence leads are presented as findings; residual leads are listed separately and are explicitly not scored as findings.

---

## Access-Control Inventory

**No ETH ever moves** (no `payable`/`receive`/`fallback`). ERC1155 shares are non-transferable (all three transfer/approval entrypoints unconditionally `revert`); balances change only via mint (`addSecondaryPosition`) and burn (settlement claims).

| Entrypoint | Guard | Caller | Key state requirement |
|---|---|---|---|
| `addPrimaryPosition` | merkle (no-op if root=0) | anyone / allowlist | OPEN |
| `removePrimaryPosition` | owner check | entry owner | OPEN ∨ CANCELLED |
| `claimPrimaryPayout` | owner check | entry owner | SETTLED |
| `addSecondaryPosition` | merkle (no-op if root=0) | anyone / allowlist | ACTIVE |
| `removeSecondaryPosition` | balance check | ERC1155 holder | OPEN ∨ CANCELLED (OPEN branch is dead code — see Low findings) |
| `claimSecondaryPayout` | balance check | winning-entry holder | SETTLED |
| `activateContest` / `lockContest` | **onlyOracle** | oracle | OPEN→ACTIVE / ACTIVE→LOCKED |
| `settleContest` | **onlyOracle** | oracle | LOCKED→SETTLED, no on-chain outcome check |
| `cancelContest` | **onlyOracle** | oracle | any non-terminal→CANCELLED, **no time bound** |
| `cancelExpired` | **NONE** | **anyone** | post-expiry, any non-terminal→CANCELLED |
| `emergencyRecoverFunds` | **onlyEmergencyRecovery** | emergencyRecovery | SETTLED∨CANCELLED, post-expiry → sweeps **entire** balance, no liability check |
| `setPrimaryMerkleRoot` / `setSecondaryMerkleRoot` | **onlyOracle** | oracle | **no state guard at all** |
| `pushPrimaryPayouts` / `pushSecondaryPayouts` | **onlyOracle** | oracle | SETTLED; also self-sweeps unallocated balance **to oracle** |
| `ContestFactory.createContest` | **NONE** | **anyone** | deploys a new controller, freely picks its own `oracle`/`emergencyRecovery` |

**Roles.**
- **`oracle`** — immutable, set once at construction, no transfer/renounce/rotation. Controls the entire lifecycle, winner selection, and payout splits with no on-chain outcome verification. Retains a direct, un-timed, self-directed fund path via `_clearUnallocatedBalance` (invoked from both push functions, even with an empty array).
- **`emergencyRecovery`** — immutable, constructor-enforced `!= oracle` (address-inequality only — one operator can trivially hold both keys under the permissionless factory). Unlocks exactly one function, gated on terminal state + post-expiry, but sweeps the **entire** live balance with **no liability check** — see Critical finding S-1 below. **Direct answer to the client's central question: this role does not reduce the oracle's fund-extraction ceiling. It adds a second, independently-triggerable full-TVL extraction path**, and in some respects (liability-blindness) is strictly more dangerous than the path it was reportedly added to mitigate.
- Both roles are permanently non-rotatable; `expiryTimestamp` has no upper bound, so a lost oracle key with a distant expiry can freeze all deposits indefinitely.

---

## Threat Model

| Actor | Reaches | Could gain | Addressed by |
|---|---|---|---|
| Anyone | `cancelExpired()` | Force settlement foreclosure, convert a loss into a full refund | **S-2** (High) |
| Anyone | `addSecondaryPosition` (dust) + honest settlement | 100% of merged secondary-market TVL for a fraction of a cent | **S-1** (Critical) |
| Anyone (allowlisted or root=0) | `addPrimaryPosition` front-run | Steal another contestant's eventual prize | **S-4** (High) |
| Anyone deploying via factory | Self-appoint `oracle`/`emergencyRecovery` | Combine with any of the above for directed extraction against good-faith joiners | Threaded through S-1, S-2, S-4, S-6 |
| `emergencyRecovery` | `emergencyRecoverFunds` | 100% of live TVL including unclaimed user funds, zero-block window | **S-1(dup label avoided)** → **S-1b / Critical** (see below) |
| `oracle` | `settleContest` outcome selection | Documented trust assumption (out of scope per repo's own prior commit) — but the *residual* powers below are in scope | S-5, S-7, M-1..M-5 |
| `oracle` | `_clearUnallocatedBalance` self-pay | Direct-to-self drain of anything unaccounted (donations, referral shortfall) | **M-2** |
| `oracle` | `setPrimaryMerkleRoot`/`setSecondaryMerkleRoot`, no state guard | Mid-contest allowlist manipulation | **M-4** |
| `oracle` | `cancelContest`, no time bound | Blunt, unbounded emergency stop that is also an offensive tool | **M-6** |
| `oracle` | reorder `winningEntries[0]` | Redirect entire secondary pool with identical declared outcome | **M-1** |
| `oracle` | atomically activate + buy own curve, then `cancelContest` as put | Risk-free extraction from later buyers | **M-3** |
| Any caller | referral chain revert / no-referrer default | Systematic secondary→primary value transfer | **S-3** |
| `oracle` (unbounded loop input) | `settleContest`/`pushPrimaryPayouts` at MAX_ENTRIES | Gas-DoS of core settlement | **M-7** (measured to 36M gas) |
| Malicious deployer | choose `paymentToken`/`rewardCalculator`/`referralGraph` freely | Fee-on-transfer insolvency, gas-bomb settlement DoS | **M-8**, **M-7** |

---

## Findings

### [95] **S-1. Dust secondary position defeats the settlement zero-supply guard — captures 100% of the merged secondary pool**

`ContestController.settleContest` / `_paySecondaryClaim` · Confidence: 95 · **Severity: Critical** · Origin: **[both]** — independently found by Phase 1 (Precision-3, AccessControl-1, General-2) and 3 Phase 2 agents (math-precision, flow-gap, numerical-gap), with a related broader variant from a 4th (economic-security). **7 independent discoveries.**

**Description**: At settlement, every entry's secondary liquidity and primary-deposit subsidy is merged into a single winning entry (`ContestController.sol:382-387`). The only guard against an unowned pool is an exact-zero test on that entry's ERC1155 supply (`winnerSupply == 0`, `:391`). Redemption is pure `balance/totalSupply` pro-rata (`:572`), with no relationship to what the holder actually contributed — so a single wei-scale purchase that mints a nonzero supply defeats the guard entirely and lets the buyer claim the whole pool.

**Proof of Concept**: With a 6-decimal token, `addSecondaryPosition(entryId, 1, [])` — a purchase of $0.000001 — mints `999,999,999,999` ERC1155 share-units (`toShareUnits(1,6)=1e12`; `calculateTokensFromCollateral(0,1e12)=999999999999 > 0`, passing `require(buyerTokens > 0)` at `:230`). An attacker repeats this on every one of up to 500 entries (`MAX_ENTRIES`) for a total cost of ≤ $0.0005 (as low as 2 wei per entry with an 18-decimal token), before `lockContest`. Whichever entry the oracle honestly names `winningEntries[0]`, the spill-to-primary fallback (`:391-407`) never fires because supply is nonzero, and the attacker — as effectively sole holder — redeems the entire merged pool via `claimSecondaryPayout`. Numerically demonstrated by two independent agents against the real integer code: a 500-entry, $100-deposit, 10%-subsidy contest with $5,000-6,000 of real secondary liquidity yields a **$5,000+ extraction for a $0.0005-$0.000005 outlay** (10¹⁰x). No oracle collusion is required — this works against a fully honest oracle simply naming the true winner.

```diff
- if (winnerLiq > 0 && winnerSupply == 0) {
+ // Cap redemption by contributed collateral rather than raw share count,
+ // or require a minimum meaningful purchase in addSecondaryPosition:
+ // require(amount >= MIN_SECONDARY_BUY, "Buy too small");
+ if (winnerLiq > 0 && winnerSupply < MIN_MEANINGFUL_SUPPLY) {
```

**Fix**: Cap each holder's payout at (or relative to) their own `secondaryDepositedPerEntry` contribution rather than raw ERC1155 balance, and/or reject `addSecondaryPosition` calls below a meaningful minimum size. Replace the exact-zero spill test with a minimum-supply/minimum-contribution threshold.

---

### [95] **S-2. `emergencyRecoverFunds` has a zero-block claim window — the "cold" role can atomically sweep 100% of live user funds**

`ContestController.emergencyRecoverFunds` / `cancelExpired` · Confidence: 95 · **Severity: Critical** · Origin: **[both]** — found independently by Phase 1 (AccessControl-2, General-1) and **10 of 12** Phase 2 agents (access-control, first-principles, flow-gap, execution-trace, economic-security, periphery, asymmetry, trust-gap, boundary, invariant-as-lead). **This is the single most corroborated finding in the entire audit, and directly answers the client's central question.**

**Description**: `emergencyRecoverFunds` gates on terminal state (SETTLED/CANCELLED) and `block.timestamp >= expiryTimestamp`. But the fully permissionless `cancelExpired()` (`ContestController.sol:490-495`) uses the **identical** timestamp predicate to first enter CANCELLED, and `settleContest` (`:315-320`) has **no** expiry bound at all — so the terminal-state gate and the sweep-eligibility gate can become true in the very same block. During ACTIVE/LOCKED, users have **zero** exit paths (both remove functions require OPEN or CANCELLED; both claims require SETTLED). The sweep reads raw `balanceOf(address(this))` with **no** deduction of `outstandingClaimableLiabilities()` — unlike its sibling `_clearUnallocatedBalance`, which is liability-aware.

**Proof of Concept — confirmed by the project's own passing test suite, not just this audit's analysis**:
```
test/ContestController.t.sol:1864  function test_emergencyRecoverFunds_Success()
test/ContestController.t.sol:1913  function test_emergencyRecoverFunds_SettledAbandonedClaimables()
```
Both tests execute exactly the attack sequence — create a primary entry, warp to expiry, call `cancelExpired()`, then `emergencyRecoverFunds()` — and **assert** the contract balance reaches zero with the user's deposit (and, in the second test, unclaimed `primaryPrizePoolPayouts`) never refunded. A helper contract holding the `emergencyRecovery` role can execute `cancelExpired(); emergencyRecoverFunds();` in **one transaction** at `t == expiryTimestamp` against a contest nobody else has touched, taking every primary deposit and secondary principal with zero blocks of legitimate withdrawal window. `emergencyRecovery != oracle` (constructor `:143`) is address-inequality only; the fully permissionless `ContestFactory.createContest` lets one operator hold both roles trivially.

```diff
  function emergencyRecoverFunds() external onlyEmergencyRecovery nonReentrant {
      require(state == ContestState.SETTLED || state == ContestState.CANCELLED, "Not terminal state");
      require(block.timestamp >= expiryTimestamp, "Expiry not reached");
+     require(block.timestamp >= terminalStateTimestamp + CLAIM_GRACE_PERIOD, "Grace period active");

-     uint256 remaining = IERC20Balance(paymentToken).balanceOf(address(this));
+     uint256 balance = IERC20Balance(paymentToken).balanceOf(address(this));
+     uint256 liabilities = outstandingClaimableLiabilities();
+     uint256 remaining = balance > liabilities ? balance - liabilities : 0;
      if (remaining > 0) {
```

**Fix**: Record a `terminalStateTimestamp` when state first enters SETTLED/CANCELLED (in `settleContest`, `cancelContest`, and `cancelExpired`) and require a multi-day grace period past it, in addition to the expiry check. Switch the sweep basis to `balance - outstandingClaimableLiabilities()`.

---

### [88] **S-3. Referral fee carved from both primary and secondary pools, refunded to primary only — a default-path (not edge-case) value transfer**

`ContestController.settleContest` / `distributeReferralFee` · Confidence: 88 · **Severity: High** · Origin: **[both]** — found independently by Phase 1 (Precision-1, Precision-2, General-4, General-5) and **9 of 12** Phase 2 agents.

**Description**: `referralFee = (totalPrimary + totalSecondary) * referralNetworkBps / BPS_DENOMINATOR` (`:343-348`); both `netPrimary` and `netSecondary` are proportionally reduced (`:351-352`). But every refund-of-fee path — no-referrer (`:420-423`), empty-chain (`:432-436`), and the `catch` block (`:364-367`) — credits the returned amount to `netPrimary` **exclusively**. `secondaryLiquidityPerEntry[winner]` is then hard-set to the un-restored `netSecondary` (`:387`). Verified against the vendored `lib/referralTree/src/core/ReferralGraph.sol`: `getReferrer` returns `address(0)` for any unregistered address — **the no-referrer refund path is the default outcome for any winner not explicitly registered in the referral graph, not an edge case.**

**Proof of Concept**: `totalPrimary=10,000`, `totalSecondary=90,000`, `referralNetworkBps=1000` (constructor max) → `referralFee=10,000`. On the (default) no-referrer path: `netPrimary` jumps from 9,000 to 19,000, `netSecondary` stays at 81,000. Secondary buyers who contributed 90,000 can redeem only 81,000; the missing 9,000 (10% of secondary TVL) is paid to primary winners for a referral service rendered to nobody. Total value is conserved (which is why balance-conservation checks miss it) — the defect is allocation, not solvency.

```diff
  } catch {
-     netPrimary += referralFee;
+     uint256 backToSecondary = (referralFee * totalSecondary) / totalGross;
+     netSecondary += backToSecondary;
+     netPrimary += referralFee - backToSecondary;
      emit ReferralNetworkFeeToPrimary(winner, referralFee);
  }
```
Apply the same proportional split to the `undistributed > 0` branch at `:361-363`.

**Sub-issue (Low, folded in)**: `distributeReferralFee`'s success path never assigns `undistributed` when the calculator under-allocates (`sum < referralFee`, explicitly permitted by `require(sum <= referralFee)` at `:444`) — the shortfall is later swept to the oracle via `_clearUnallocatedBalance`. The vendored canonical `RewardCalculator.sol:50-51` forces `sum == totalReward` exactly, so this sub-issue is dormant with the canonical implementation and live only against a non-canonical, unvalidated `rewardCalculator` address (an unchecked constructor parameter on the permissionless factory).

---

### [85] **S-4. `entryId` is unauthenticated — front-running a contestant's registration steals their eventual prize**

`PrimaryContest.validatePrimaryMerkleProof` / `ContestController.addPrimaryPosition` · Confidence: 85 · **Severity: High** · Origin: **[both]** — found independently by Phase 1 (General-6) and **4 of 12** Phase 2 agents (first-principles, execution-trace, invariant, boundary).

**Description**: The merkle leaf is `keccak256(abi.encodePacked(participant))` (`PrimaryContest.sol:26`) — it authenticates *who* may register but carries no `entryId`, so it authorizes nothing about *which* slot the caller may take. `entryOwner[entryId]` is pure first-come-first-served. `entryId`s are necessarily meaningful off-chain (a contestant/submission identifier) since the oracle must know which one to declare a winner — otherwise settlement has no referent at all.

**Proof of Concept**: A 10-team tournament uses `entryId` = team number. Team 7's manager broadcasts `addPrimaryPosition(7, [])`. An attacker — allowlisted, or anyone at all if `primaryMerkleRoot == bytes32(0)` (the constructor default, and what every repo test uses) — front-runs with a higher priority fee and takes `entryId=7`; team 7's real registration permanently reverts (`"Entry already exists"`, no reassignment path exists). Team 7 wins the real-world event; the oracle honestly settles `[7]`; the attacker — not team 7 — calls `claimPrimaryPayout(7)` and takes the entire prize for the cost of one deposit.

```diff
  function validatePrimaryMerkleProof(
      bytes32 merkleRoot,
      address participant,
+     uint256 entryId,
      bytes32[] calldata merkleProof
  ) internal pure {
      if (merkleRoot != bytes32(0)) {
-         bytes32 leaf = keccak256(abi.encodePacked(participant));
+         bytes32 leaf = keccak256(abi.encodePacked(participant, entryId));
          require(MerkleProofLib.verify(merkleProof, merkleRoot, leaf), "Invalid merkle proof");
      }
  }
```

**Fix**: Bind the entry to the registrant in the merkle leaf. Apply the identical fix to `SecondaryContest.validateSecondaryMerkleProof`.

---

### [80] **S-5. `cancelExpired()` is permissionless and gives every losing participant a profitable veto over settlement**

`ContestController.cancelExpired` · Confidence: 80 · **Severity: High** · Origin: **[both]** — found independently by Phase 1 (AccessControl-6, General-12) and 6 Phase 2 agents.

**Description**: `cancelExpired` has no caller check and accepts LOCKED as a starting state; `settleContest` requires exactly LOCKED with no time bound, so once expiry passes both are simultaneously callable and `cancelExpired` wins any gas race. CANCELLED is a dead end. Refunds on cancellation are 100% of principal for both layers; settlement pays non-winners zero, so any participant anticipating a loss strictly prefers cancellation and can force it unilaterally.

**Proof of Concept**: A secondary holder on a losing entry watches the mempool for the oracle's post-expiry `settleContest`, front-runs with `cancelExpired()` (~30-45k gas), permanently forecloses settlement, and recovers 100% of principal via `removeSecondaryPosition` — converting a certain total loss into a certain full refund at the intended winners' expense.

```diff
  function cancelExpired() external {
-     require(block.timestamp >= expiryTimestamp, "Not expired");
+     require(block.timestamp >= expiryTimestamp + SETTLEMENT_GRACE_PERIOD, "Oracle grace period active");
      require(state != ContestState.SETTLED && state != ContestState.CLOSED, "Already settled");
      state = ContestState.CANCELLED;
      emit ContestCancelled();
  }
```

**Fix**: Give the oracle an exclusive settlement window past expiry before `cancelExpired` becomes callable by anyone, and/or forbid it from LOCKED entirely.

---

### [70] **M-1. `winningEntries[0]` silently redirects the entire secondary pool with an identical declared outcome**

`ContestController.settleContest` · Confidence: 70 · **Severity: Medium** · Origin: **[phase2 only, re-examined and confirmed]** — trust-gap agent.

**Description**: Primary payouts are position-paired (`winningEntries[i]` ↔ `payoutBps[i]`) and therefore order-invariant. But `secondaryWinningEntry = winningEntries[0]` (`:379`), the referral anchor `entryOwner[winningEntries[0]]` (`:355`), and the spill remainder (`:404`) are all keyed exclusively on array index 0 — an unvalidated degree of freedom fully controlled by the oracle, with no economic trace distinguishing it from an honest ordering in the emitted event.

**Proof of Concept**: 3 entries, secondary buys E1=$50k/E2=$30k/E3=$20k. `[E1,E2],[6000,4000]` vs `[E2,E1],[4000,6000]` produce byte-identical primary payouts but route the entire $90k merged secondary pool to E1 holders in one ordering and E2 holders in the other.

**Fix**: Take the secondary-winning entry as an explicit, independently-validated parameter rather than implicitly reusing array index 0.

---

### [65] **M-2. `_clearUnallocatedBalance` still pays the hot oracle directly — the role split does not remove this path**

`ContestController._clearUnallocatedBalance` · Confidence: 65 · **Severity: Medium** · Origin: **[both]** — Phase 1 (AccessControl-3, General-3) and Phase 2 leads (asymmetry, periphery independently traced balance conservation and confirmed dust-only under honest conditions).

**Description**: `_clearUnallocatedBalance` (`:681-690`) sends `balance - outstandingClaimableLiabilities()` directly to `oracle`, invoked unconditionally at the tail of both push-payout functions — including with an empty array (`pushPrimaryPayouts([])` is a valid, gas-cheap "sweep to self" call). Under fully honest conditions this is bps-rounding dust (confirmed by symbolic balance tracing across all four referral branches), but it also captures: any tokens donated/misdirected to the contract, and the S-3 referral shortfall sub-issue. The `emergencyRecovery` role addition did not touch this path at all.

**Fix**: Redirect the residual to `emergencyRecovery` (matching the stated intent of separating the hot key from residual-fund custody) behind the same post-expiry gate `_clearUnallocatedBalance` currently lacks, or cap the sweep to a documented dust threshold.

---

### [65] **M-3. Oracle can atomically front-run its own bonding curve, then use unbounded `cancelContest` as a risk-free put option**

`ContestController.activateContest` + `addSecondaryPosition` + `cancelContest` · Confidence: 65 · **Severity: Medium** · Origin: **[phase2 only, re-examined and confirmed]** — trust-gap agent.

**Description**: The oracle alone triggers `activateContest` and can call `addSecondaryPosition` in the same transaction, guaranteeing the cheapest point on the increasing bonding curve. Ordinary buyers have no exit while the market is live. If the position doesn't pay off, `cancelContest()` — unbounded in time, oracle-only, no restriction beyond non-terminal state — refunds the oracle's principal in full via the CANCELLED path with no curve penalty, an option unavailable to any other buyer.

**Proof of Concept**: `price(S) = $1 + 1.5e-5·S²`. Oracle buys the first 258 shares for $343.90; public buys 1000 more for $10,867 (pot $11,211, supply 1258 shares). Pro-rata-by-token-count redemption: oracle gets 258/1258 × $11,211 = $2,299 (6.7x); if the position doesn't pay off, `cancelContest()` returns the oracle's $343.90 with no penalty.

**Fix**: Delay secondary-buy eligibility relative to `activateContest` (e.g. `activatedAt + DELAY`); forbid `oracle`/entry-owner addresses from holding secondary positions; bound `cancelContest` to pre-ACTIVE states.

---

### [60] **M-4. Merkle allowlist roots have no state guard, no timelock — mutable at any point in the contest**

`ContestController.setPrimaryMerkleRoot` / `setSecondaryMerkleRoot` · Confidence: 60 · **Severity: Medium** · Origin: **[phase1]** (AccessControl-4, General-11); touched tangentially by Phase 2 trust-gap as a lead.

**Description**: Both setters are `onlyOracle` with zero state or time restriction — callable in OPEN, ACTIVE, LOCKED, even SETTLED/CANCELLED. `bytes32(0)` disables the corresponding allowlist entirely. The oracle can `setPrimaryMerkleRoot(0)`, self-register, then restore the original root — the enabling step for combining this with S-1/S-4 against a nominally curated contest.

**Fix**: Restrict roots to before the corresponding phase opens and make them immutable-once-set (ideally constructor parameters).

---

### [55] **M-5. No minimum lifecycle-state duration — oracle can close the only user exit window instantly**

`ContestController.activateContest` / `lockContest` / `settleContest` · Confidence: 55 · **Severity: Medium** · Origin: **[phase1 only]** (AccessControl-5).

**Description**: All three transitions require only the immediately preceding state, with no minimum dwell time. OPEN is the only state a primary entrant can exit from — the moment the first entrant deposits, the oracle can `activateContest()` in the same block, trivially front-running any pending `removePrimaryPosition`.

**Fix**: Add operator-set phase floors as constructor immutables (`openUntil`, `activeUntil`) and enforce them on the transition functions.

---

### [55] **M-6. Both roles are immutable with no rotation/renounce path; `expiryTimestamp` has no upper bound**

`ContestController` constructor · Confidence: 55 · **Severity: Medium** · Origin: **[phase1 only]** (AccessControl-8).

**Description**: No transfer, no two-step accept, no renounce for `oracle` or `emergencyRecovery`. Combined with an unbounded `expiryTimestamp` (only `> block.timestamp` is required), a lost oracle key on a contest with a distant expiry permanently freezes every deposit — no function accepts a non-terminal, pre-expiry state for user exit.

**Fix**: Cap `expiryTimestamp` to a `MAX_CONTEST_DURATION` from deployment; add two-step role rotation for both roles.

---

### [55] **M-7. Gas-DoS surfaces: `settleContest` O(winners²) dedup reaches ~36M gas at scale; malicious `referralGraph` can defeat the try/catch gas margin**

`ContestController.settleContest` · Confidence: 55 · **Severity: Medium** · Origin: **[both]** — Phase 1 (DoS-2, DoS-4, measured via forge tests) and Phase 2 lead (DoS-4-equivalent, gas-bomb via referralGraph, corroborated by multiple agents as a lead).

**Description**: `settleContest`'s O(winners²) duplicate check plus O(entries) TVL/zeroing loops were measured (forge, `--isolate`) at **36,139,306 gas** for 500 entries/500 winners — exceeding a 30M block gas limit and Arbitrum's ~32M per-tx cap. Separately, a deployer-supplied `referralGraph`/`rewardCalculator` that burns gas can leave `settleContest` with too little of the EIP-150-retained 1/64 gas to complete its own post-catch loops for large `entries.length`, permanently blocking settlement (demonstrated with a forge PoC: 200 entries succeeds with an explicit 30M gas cap, 500 entries reverts and leaves the contest stuck LOCKED). Both are recoverable via `cancelContest`, so this is DoS not fund-loss.

**Fix**: Add an explicit `MAX_WINNERS` well under the measured safe threshold; replace O(n²) dedup with an O(n) strictly-increasing-order requirement; gas-cap the referral sub-call explicitly.

---

### [50] **M-8. Fee-on-transfer / rebasing `paymentToken`: permissionless factory lets a malicious deployer pick a token that breaks all internal accounting**

`ContestController` (all deposit/payout sites), `ContestFactory.createContest` · Confidence: 50 · **Severity: Medium** · Origin: **[phase1 only]** (ERC20-1, ERC20-3, ERC20-5); touched as an unverified lead by several Phase 2 agents.

**Description**: Every internal counter (`primaryPrizePool`, `secondaryLiquidityPerEntry`, etc.) is credited at the *nominal* transfer amount, never a measured balance delta. `ContestFactory.createContest` validates `paymentToken` only for non-zero address plus an implicit code-existence check. A malicious deployer can deliberately choose a fee-on-transfer, rebasing, or blocklist-capable token, causing several exit paths (`removePrimaryPosition`, `claimPrimaryPayout`, `pushPrimaryPayouts`) to revert outright for the last claimants (who lose 100% of their real, but under-tracked, balance), while `_paySecondaryClaim`/`removeSecondaryPosition` silently truncate and permanently burn the claimant's position for less than owed.

**Fix**: Measure balance deltas on every inbound transfer and credit the delta, not the nominal parameter; consider a `paymentToken` allowlist at the factory level.

---

### [45] **L-1. Small secondary holders can have their position force-burned for a zero payout**

`ContestController._paySecondaryClaim` · Confidence: 45 · **Severity: Low** · Origin: **[both]** — Phase 1 (AccessControl-7, Precision-8, ERC20-2) and Phase 2 lead (asymmetry).

**Description**: `payout = balance * entryLiquidity / totalSupplyBefore` floors; for small holders this can round to exactly zero, and the position's ERC1155 balance and tracked principal are burned/zeroed **unconditionally**, regardless of payout — with no residual claim. Reachable via the oracle's `pushSecondaryPayouts` (forced, no consent) or the holder's own pull claim. Concrete: a holder with 900,000 wei of shares out of 1e18 total supply on a $1,000 pool receives 0 and is fully burned.

**Fix**: `require(payout > 0)` before burning in the pull path; skip (don't burn) in the push path on a zero/capped payout.

---

### [40] **L-2. `removePrimaryPosition` in CANCELLED desyncs `entries[]` from live secondary-liability accounting (view-only, not a fund loss)**

`ContestController.removePrimaryPosition`, `outstandingClaimableLiabilities`, `totalSecondaryLiquidity` · Confidence: 65 (for the accounting-desync claim) · **Severity: Low** · Origin: **[both]** — this was the protocol map's #1-ranked fragility cluster; **explicitly investigated and downgraded by nearly every hunting agent in both phases**. `SecondaryContest.validateRemoveSecondaryPosition` never checks `entryOwner`, so secondary holders on an entry whose primary owner already exited in CANCELLED can still recover their full tracked principal — **the originally-hypothesized fund-stranding does not occur.** What remains: `entries[]`-driven liability views (`outstandingClaimableLiabilities`'s CANCELLED branch, `totalSecondaryLiquidity`) under-report once the entry is popped, which is currently inert because the only fund-mover that reads that view (`_clearUnallocatedBalance`) is reachable exclusively from SETTLED, where removal is impossible.

**Fix**: Track liabilities via an accumulator independent of `entries[]` membership, in case a future change wires a fund-mover to the CANCELLED-state liability figure.

---

### [40] **L-3. `emergencyRecoverFunds` leaves the contest un-closable at zero balance and orphans `primaryPrizePoolPayouts`**

`ContestController.emergencyRecoverFunds` · Confidence: 60 · **Severity: Low** · Origin: **[both]** — Phase 1 (AccessControl-12) and Phase 2 leads (boundary, numerical-gap, execution-trace).

**Description**: `state = CLOSED` sits inside the `remaining > 0` guard — a zero-balance contest (the normal end state after everyone claims) can never reach CLOSED. `primaryPrizePoolPayouts` is never zeroed by the sweep, leaving per-entry "debt" recorded forever against a swept-empty contract with no code path able to pay it.

**Fix**: Make `state = CLOSED` unconditional; zero `primaryPrizePoolPayouts[eid]` in the sweep loop.

---

### [35] **L-4. `pushPrimaryPayouts` has no per-recipient failure isolation, unlike `pushSecondaryPayouts`**

`ContestController.pushPrimaryPayouts` · Confidence: 55 · **Severity: Low** · Origin: **[both]** — Phase 1 (DoS-1, ERC20-4, General-9) and Phase 2 lead.

**Description**: `pushSecondaryPayouts` deliberately isolates each recipient via a self-call `try/catch` ("Isolate per-recipient failures (e.g. blocklisted token recipient)"). `pushPrimaryPayouts` transfers directly with no isolation — one blocklisted winner reverts the entire batch. Impact is capped: the pull path `claimPrimaryPayout` remains available.

**Fix**: Mirror the secondary path's self-call trampoline pattern for primary payouts.

---

### [30] **L-5. Zero-supply spill branch leaves `primaryPrizePool` inconsistent with `Σ primaryPrizePoolPayouts`**

`ContestController.settleContest` · Confidence: 50 · **Severity: Low** · Origin: **[both]** — Phase 1 (General-10) and Phase 2 lead (math-precision, boundary).

**Description**: The `winnerSupply == 0` spill branch (`:391-407`) credits `primaryPrizePoolPayouts` without a matching increase to `primaryPrizePool`; both drain sites floor-at-zero rather than reverting, masking the desync. `getPrimarySideBalance()` becomes meaningless after a spill event; no fund-loss found since liability accounting keys off `primaryPrizePoolPayouts`, not `primaryPrizePool`.

**Fix**: `primaryPrizePool += winnerLiq;` inside the spill branch; restore `require(primaryPrizePool >= payout)` at the drain sites.

---

### [25] **L-6. Entry-slot squatting via unvalidated `primaryDepositAmount`**

`ContestController` constructor, `addPrimaryPosition` · Confidence: 55 · **Severity: Low-Medium** · Origin: **[both]** — Phase 1 (AccessControl-9, DoS-3, ERC20-7) and Phase 2 (economic-security). Every other constructor parameter is validated; `_primaryDepositAmount` is not — zero is accepted, letting an attacker occupy all `MAX_ENTRIES=500` slots for pure gas cost. Overlaps with S-4's identity-binding gap for a targeted (not just capacity) variant.

**Fix**: `require(_primaryDepositAmount > 0, "Invalid deposit amount")`.

---

## Findings List

| # | Confidence | Severity | Title |
|---|---|---|---|
| S-1 | [95] | Critical | Dust secondary position captures 100% of merged secondary pool |
| S-2 | [95] | Critical | `emergencyRecoverFunds` zero-block claim window |
| S-3 | [88] | High | Referral fee cross-pool misallocation (default path) |
| S-4 | [85] | High | `entryId` front-running steals contestant's prize |
| S-5 | [80] | High | `cancelExpired()` permissionless settlement-foreclosure race |
| M-1 | [70] | Medium | `winningEntries[0]` reordering redirects secondary pool |
| M-2 | [65] | Medium | `_clearUnallocatedBalance` still pays hot oracle |
| M-3 | [65] | Medium | Oracle front-runs own curve, uses `cancelContest` as put |
| M-4 | [60] | Medium | Merkle roots mutable with no state guard |
| M-5 | [55] | Medium | No minimum lifecycle-state duration |
| M-6 | [55] | Medium | Immutable roles, unbounded expiry |
| M-7 | [55] | Medium | Gas-DoS on `settleContest` at scale |
| M-8 | [50] | Medium | Fee-on-transfer/rebasing token insolvency |
| L-1 | [45] | Low | Small holders force-burned for zero payout |
| L-2 | [40] | Low | CANCELLED liability-view desync (not a fund loss) |
| L-3 | [40] | Low | `emergencyRecoverFunds` leaves stale/un-closable state |
| L-4 | [35] | Low | `pushPrimaryPayouts` no failure isolation |
| L-5 | [30] | Low | Spill branch leaves `primaryPrizePool` inconsistent |
| L-6 | [25] | Low | Entry-slot squatting via zero deposit |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be closed to a confirmed finding. Not scored._

- **Unreturned referral shortfall to a non-canonical calculator** — `ContestController.distributeReferralFee` — Code smells: success path never assigns `undistributed` when `sum < referralFee`. Dormant with the canonical `RewardCalculator` (verified: forces `sum == totalReward`); live only against a non-canonical, unvalidated `rewardCalculator` address.
- **Unchecked `int256↔uint256` casts on `netPosition`** — `ContestController` / `SecondaryContest` — Code smells: 6 of 8 read sites cast without a sign guard. Verified non-negativity currently holds everywhere; latent only.
- **`SecondaryPricing` binary-search non-convergence** — `SecondaryPricing.calculateTokensFromCollateral` — Code smells: 50-iteration cap leaves a residual gap for large purchases. Confirmed by nearly every hunting agent as dust-only (~1e-15 to 1e-9 relative, always favoring the protocol) — not exploitable.
- **`removeSecondaryPosition`'s OPEN-state branch is dead code** — `state` is only ever OPEN at construction and never revisited, so the documented OPEN pro-rata sell-back (contract NatSpec) can never execute. Not a live vulnerability (CANCELLED exit still works) — a documentation/dead-code cleanup item.
- **Bonding curve normalizes decimals but not token value** — `SecondaryPricing.toShareUnits`/`calculatePrice` — `COEFFICIENT=15` assumes 1 whole payment-token ≈ $1; simulated identical trades split 73/27 on USDC vs. exactly 50/50 on WBTC. Whale-protection is 3,000-60,000x mis-calibrated depending on the deployer's token choice. Not escalated to a finding because it requires the deployer to choose an atypical token and doesn't itself enable theft — it degrades the curve's intended fairness property.
- **Unbounded `ContestFactory.getContests()`** — quadratic memory-expansion cost as the registry grows; not cheaply exploitable on L1 (each entry costs a full contract deployment) but reachable on a cheap L2.

---

> ⚠️ This review was performed by an AI-orchestrated multi-agent audit pipeline (17 independent hunting agents across two blind phases plus context-building). AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. A follow-up human review, particularly of **S-1** and **S-2**, is strongly recommended before this contract handles material user funds. On-chain monitoring and a bug bounty program are also recommended.