# 🔐 Security Review — contestCatalyst (ContestController / ContestFactory)

**Repo:** [`MagRelo/contestCatalyst`](https://github.com/MagRelo/contestCatalyst)
**Commit reviewed:** `b02f0a77867377681374dc8aef7ae524e47e11ff` — verified reachable as `main` HEAD on the remote at time of audit (`git ls-remote` confirmed). Not pinned by the client; the job description gave only the repo URL, so the default branch HEAD at audit time is the target.
**Scope:** `src/ContestController.sol` · `src/ContestFactory.sol` · `src/PrimaryContest.sol` · `src/SecondaryContest.sol` · `src/SecondaryPricing.sol` (1,123 LOC). `lib/referralTree` (a separate repo, `MagRelo/referralTree` @ `e81f78b`) supplies `IReferralGraph`/`IRewardCalculator` implementations referenced by `ContestController` — read for external-surface/black-box context only, not audited as an in-scope target.
**Client's ask:** general audit — "analyze this repo for all issues" (job description gave no narrower scope).
**Methodology:** three-phase audit — Phase 0 context building (protocol map + access-control inventory + threat catalog, opus, 3 agents) → Phase 1 breadth (6 ethskills domain agents: general, precision-math, erc20, erc721/ERC1155, dos, access-control, opus) → Phase 2 depth (12 pashov attacker-mindset agents — 9 specialty + 3 gap-hunter — run blind to Phase 1 findings, opus, several performing live numeric simulation and empirical `forge` gas measurement) → Phase 3 hybrid reconciliation with a Phase-0-driven coverage gate.
**Prior audits on this repo:** `docs/audit-report.md` (commit `d24958c…`, an earlier leftclaw engagement, job #391), `docs/audit-report-2.md` (commit `6a93dc7…`), `docs/audit-report-3.md` (commit `4dd88f6…`) — three prior engagements against earlier commits of this same repo. Per this job's protocol, every finding below was derived independently from this run's own Phase 0/1/2 agents against the current commit; no finding was copied from the prior reports. Current HEAD already fixes several issues those reports raised (`emergencyRecoverFunds` removed, explicit `secondaryWinner` parameter instead of `winningEntries[0]`, try/catch isolation on referral and push payouts, `MAX_ENTRIES` cap, `SETTLEMENT_GRACE_PERIOD`) — this is a materially hardened revision, and the findings below reflect what remains.

---

## Severity counts

**Severity counts:** 1 Critical · 6 High · 7 Medium · 20 Low · 10 Informational

---

## Reconciliation summary

- **Overlap (found independently by both phases, or by multiple agents blind to each other):** extraordinarily high on the top findings. The Critical finding (merged secondary-pool redemption mismatch) was independently rediscovered by **9 of the 18 total hunting agents** via completely different lenses (breadth `general` checklist, pashov `trust-gap`, `invariant`, `flow-gap`, `first-principles`, `boundary`, `economic-security`, `math-precision`) — including a formal proof that the exploit is risk-free. The `distributeReferralFee` unassigned-return bug was independently found by **essentially all 18 agents** across both phases.
- **Phase-1-only:** the referral-graph gas/return-data-bomb DoS on `settleContest` was found in breadth by `general` and `access-control` (the latter as a lead) and _empirically confirmed_ with `forge` gas measurements by the `dos` breadth agent — this measurement is the basis for High-1's confidence.
- **Phase-2-only:** the settlement-reveal front-run (buying into the known winner before `lockContest` confirms) and the risk-free all-entries hedge with a formal profit proof were phase-2-only refinements of the phase-1 dust-holder finding.
- **Re-examined leads kept:** all phase-unique findings were cross-checked against source during reconciliation and confirmed. **Demoted:** the "share-count-vs-capital redemption" finding (late buyers on the _winning_ entry losing money) is standard bonding-curve tokenomics, not a code defect — demoted to an Informational design note. The "operator self-dealing" framing of the Critical finding is subsumed by its fully-unprivileged variant and not reported separately.
- **Coverage:** all 22 external/public state-changing entrypoints in the Phase-0 access-control inventory were examined by at least one phase. All threat-catalog rows were addressed. **Coverage holes closed this pass: 0** — both phases already covered every entrypoint and catalog row independently.
- **Confidence floor:** findings below carry an explicit `confidence` (0–100). Everything Low severity and above is reported as a finding; nothing scored below 50 confidence survived to reporting (a handful of narrower leads are listed in **Leads** at the end, unscored).

---

## Access-Control Inventory

**One role: `operator`** — `address public immutable operator` (`ContestController.sol:43`), set once in the constructor (non-zero-checked `:146`). **Immutable — no rotation, transfer, renounce, or two-step handoff exists anywhere in the codebase.** Enforced by a single modifier, `require(msg.sender == operator, "Not operator")` (`:130`).

| Function                                                       | Guard                                                                                            | Caller                                                                                      | Moves value?                                                                                                                                                                                                                   |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `addPrimaryPosition`                                           | `nonReentrant`; merkle proof **no-op when `primaryMerkleRoot==0`** (the default from deployment) | any address                                                                                 | pulls deposit                                                                                                                                                                                                                  |
| `removePrimaryPosition`                                        | `nonReentrant`; `entryOwner==msg.sender`; state∈{OPEN,CANCELLED}                                 | entry owner                                                                                 | refunds deposit in full                                                                                                                                                                                                        |
| `claimPrimaryPayout`                                           | `nonReentrant`; `entryOwner==msg.sender`; state==SETTLED                                         | entry owner                                                                                 | pays out                                                                                                                                                                                                                       |
| `addSecondaryPosition`                                         | `nonReentrant`; merkle proof no-op when root==0; state==ACTIVE                                   | any address                                                                                 | pulls buy, mints ERC1155                                                                                                                                                                                                       |
| `removeSecondaryPosition`                                      | `nonReentrant`; balance≥amount; state∈{OPEN,CANCELLED}; **no `entryOwner` check**                | any share holder                                                                            | pays out, burns (OPEN branch is dead code — see L1)                                                                                                                                                                            |
| `claimSecondaryPayout`                                         | `nonReentrant`; balance>0; state==SETTLED; entry==winner                                         | any share holder of winning entry                                                           | pays out, burns                                                                                                                                                                                                                |
| `activateContest` / `lockContest`                              | `onlyOperator`; state gate. **Not `nonReentrant`**                                               | operator                                                                                    | no                                                                                                                                                                                                                             |
| `settleContest`                                                | `onlyOperator`; `nonReentrant`; state==LOCKED; array/winner validation                           | operator — **fully trusted inputs, zero on-chain outcome verification, by explicit design** | indirectly (referral self-call)                                                                                                                                                                                                |
| `distributeReferralFee`                                        | self-call only: `msg.sender==address(this)`                                                      | only the contract itself (try/catch target of `settleContest`)                              | yes, up to 10% of TVL                                                                                                                                                                                                          |
| `cancelContest`                                                | `onlyOperator`; state∉{SETTLED,CLOSED}. **Not `nonReentrant`**                                   | operator                                                                                    | no                                                                                                                                                                                                                             |
| `setPrimaryMerkleRoot`/`setSecondaryMerkleRoot`                | `onlyOperator`; **no state gate, no timelock, any phase, unlimited times**                       | operator                                                                                    | no                                                                                                                                                                                                                             |
| `cancelExpired`                                                | **permissionless**; `now≥expiry+1day`; state∉{SETTLED,CLOSED} — **accepts LOCKED**               | anyone                                                                                      | no directly; unlocks full refunds                                                                                                                                                                                              |
| `pushPrimaryPayouts`/`pushSecondaryPayouts`                    | `onlyOperator`; `nonReentrant`; state==SETTLED                                                   | operator, unbounded array                                                                   | yes, batched, per-recipient isolated                                                                                                                                                                                           |
| `payPrimaryPayoutExternal`/`paySecondaryClaimExternal`         | self-call only                                                                                   | only the contract itself                                                                    | yes                                                                                                                                                                                                                            |
| `setApprovalForAll`/`safeTransferFrom`/`safeBatchTransferFrom` | unconditional revert                                                                             | nobody                                                                                      | no                                                                                                                                                                                                                             |
| `ContestFactory.createContest`                                 | **none — fully permissionless**                                                                  | anyone                                                                                      | deploys a `ContestController` with fully caller-chosen `paymentToken`/`operator`/`referralGraph`/`rewardCalculator` — **the deployer is not the operator and is never named as a trusted party in the contract's own NatSpec** |

**Undisclosed trust boundary (load-bearing for High-2, High-5, High-6):** the contract's own comment (`ContestController.sol:30-33`) names only `operator` as trusted. The caller of the permissionless `ContestFactory.createContest` permanently fixes `paymentToken`, `referralGraph`, `rewardCalculator`, and `expiryTimestamp` — and need not be the operator.

---

## Threat Model

| Actor                                        | Reaches                                                                    | Could gain                                                                                            | Invariant / disclosure gap                                                                |
| -------------------------------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Any address                                  | `addSecondaryPosition` on every entry for ~$500–1000 total                 | guaranteed post-hoc redemption of the entire merged contest-wide secondary pool, whatever the outcome | **Critical-1** — cost is per-entry, redemption is contest-wide; no invariant ties the two |
| Any address (factory caller, not `operator`) | `ContestFactory.createContest`'s `referralGraph`/`rewardCalculator` params | up to `referralNetworkBps` (≤10%) of all TVL in an honestly-operated contest                          | **High-2, High-6** — undisclosed trust boundary                                           |
| Any address                                  | `distributeReferralFee`'s tolerance for `sum < referralFee`                | strands the shortfall, later sweepable to a self-controlled position                                  | **High-1**                                                                                |
| Any losing participant                       | `cancelExpired()` while `LOCKED`                                           | full refund instead of a forfeited stake, permanently voiding settlement                              | **High-4**                                                                                |
| Any address (allowlist unset or wrong leaf)  | `addPrimaryPosition` with an arbitrary `entryId`                           | another contestant's eventual prize                                                                   | **High-3**                                                                                |
| Contest creator                              | `paymentToken` choice                                                      | insolvency-driven fund misallocation between primary/secondary claimants                              | **High-5**                                                                                |
| Deployer of a hostile `referralGraph`        | gas/return-data bomb inside `distributeReferralFee`'s try/catch            | permanent DoS of `settleContest` above ~150 entries                                                   | **High-6**                                                                                |
| Operator (self, informational)               | lifecycle timing, root mutation                                            | griefing within the disclosed trust boundary                                                          | addressed — Low findings only                                                             |

---

## Findings

### Critical

**1. Merged cross-entry secondary pool lets anyone hedge every outcome for a fixed, tiny cost and redeem risk-free — mathematically proven to never lose**

**Severity:** Critical
`ContestController.addSecondaryPosition` / `settleContest` / `_paySecondaryClaim` — `ContestController.sol:207-233`, `:392-419`, `:577-605`
**Confidence:** 97 · **Origin:** `[phase1: general]` `[phase2: agents 3,5,7,9,11,12 — economic-security, invariant, first-principles, boundary, trust-gap, flow-gap]` `[phase2: agent 1 math-precision — formal proof]`

**Root cause.** A secondary buy is priced against _only the target entry's own supply_ (`SecondaryPricing.calculatePrice(netPosition[entryId])`), but at settlement `settleContest` unconditionally sweeps **every** entry's `secondaryLiquidityPerEntry` and `secondaryPrimarySubsidyPerEntry` (`:392-397`) into a single pool owned by `secondaryWinningEntry`, redeemed pro-rata by that one entry's ERC1155 share count (`:583`). Cost is per-entry; the claim is contest-wide. Nothing ties the two together, and the sole safety valve — `winnerLiq > 0 && winnerSupply == 0` (`:401`) — is an **exact-equality** check that one wei of supply permanently disables.

```solidity
// ContestController.sol:392-403
for (uint256 k = 0; k < entries.length; k++) {
    uint256 eid = entries[k];
    secondaryLiquidityPerEntry[eid] = 0;
    secondaryPrimarySubsidyPerEntry[eid] = 0;
}
secondaryLiquidityPerEntry[secondaryWinningEntry] = netSecondary;   // ALL entries' TVL, in one bucket

uint256 winnerSupply = uint256(netPosition[secondaryWinningEntry]);
uint256 winnerLiq = secondaryLiquidityPerEntry[secondaryWinningEntry];
if (winnerLiq > 0 && winnerSupply == 0) {   // exact-zero guard — one wei of supply defeats it
```

```solidity
// _paySecondaryClaim, ContestController.sol:582-583
uint256 entryLiquidity = secondaryLiquidityPerEntry[entryId];
uint256 payout = entryLiquidity > 0 ? (balance * entryLiquidity) / totalSupplyBefore : 0;
```

**Proof (converged trace, corroborated independently across 7 agents with different numbers, all showing the same shape):** `minSecondaryPurchaseAmount` is one whole payment-token unit ($1 for a 6-decimal stablecoin). `SecondaryPricing.calculatePrice(0) == BASE_PRICE`, so the first buy on any virgin entry is priced at the floor. Buying $1 on **every** entry in a 500-entry contest (max cost $500, independent of pool size) guarantees holding nonzero supply on whichever entry the operator ultimately names `secondaryWinner` — defeating the `==0` guard unconditionally and guaranteeing a claim on the entire merged pool.

- Boundary agent's exact-integer trace: $1 buy on entry #99 (otherwise zero-supply) → `claimSecondaryPayout` pays **$87,358.20** instead of the $1 outlay (87,358×) — and diverts the entire sum away from the legitimate primary-winner spill it would otherwise have received.
- Invariant agent's trace: $3 total outlay across 3 entries → $9,002.70 claimed.
- Math-precision agent's formal argument: ROI = (average per-entry price the honest pool paid) / `BASE_PRICE` ≥ 1 always, by construction of a monotonically non-decreasing curve — i.e. the strategy is **provably non-losing** for any pool configuration, verified numerically from $500 floor case (1.00×) up through $50M pools (37×) up to a fully-concentrated-elsewhere case (2001×, capturing $1,000,500 that would otherwise have gone to $1,000,000 of honest bettors on the real favorite).
- Flow-gap agent's variant: because `settleContest`'s winner is revealed in public calldata, an attacker can even wait until the operator's `lockContest`+`settleContest` pair is broadcast and front-run a targeted buy into the now-known winner before `lockContest` confirms, for a quantified $2,324 profit on a $5,000 buy with zero outcome risk.
- Economic-security agent's independent trace at 100-entry scale: identical $100 buy nets 720× EV-weighted return on a thin entry vs. 105× on a liquid favorite for the same dollar — the pricing carries zero information about win probability.

**Impact:** unauthenticated, requires no operator collusion, no code bug beyond the missing conservation link, and is (per the formal argument) risk-free for the attacker. Direct fund loss to every other secondary bettor and to primary winners who would otherwise receive the zero-supply spill.

**Fix:** Redeem the merged pool proportional to _contributed capital_ (`secondaryDepositedPerEntry[holder][entryId]` relative to the entry's own pre-merge `secondaryLiquidityPerEntry`), not raw post-merge share count — or replace the exact-zero spill guard with a economically-meaningful floor (e.g. require the winning entry's own pre-merge liquidity to exceed some minimum fraction of the merged total) and cap each holder's redemption at their pro-rata share of the entry's _own_ contributed liquidity, spilling any cross-entry excess to primary payouts instead.

---

### High

**2. `distributeReferralFee` never returns the shortfall when the reward calculator under-distributes — up to 10% of TVL is carved from both prize pools and restored to neither**

**Severity:** High
`ContestController.distributeReferralFee()` — `ContestController.sol:433-472`, guard at `:464`
**Confidence:** 95 · **Origin:** near-universal — `[phase1: general-7, access-control-6, precision-math-8]` `[phase2: all 12 agents found this independently — access-control, invariant, execution-trace, asymmetry, periphery, first-principles, boundary, trust-gap, economic-security, math-precision, numerical-gap, flow-gap]`

```solidity
// ContestController.sol:462-473
uint256[] memory amounts = IRewardCalculator(rewardCalculator).calculateRewards(referralFee, chain.length);
require(amounts.length == chain.length, "Reward length mismatch");
uint256 sum;
for (uint256 i = 0; i < amounts.length; i++) { sum += amounts[i]; }
require(sum <= referralFee, "Rewards exceed fee");     // deliberately permits sum < referralFee

for (uint256 i = 0; i < chain.length; i++) {
    if (amounts[i] > 0) { SafeTransferLib.safeTransfer(ERC20(paymentToken), chain[i], amounts[i]); }
}
emit ReferralNetworkFeeDistributed(winner, payoutAnchor, referralFee, chain, amounts);
}   // <-- falls off the end; named return `undistributed` stays at its default 0
```

The two no-payable-referrer early-return paths correctly `return referralFee` (`:441`, `:455`). The distributing path's `require` is a deliberate `<=`, not `==` — the code anticipates a calculator that under-allocates — but never assigns `undistributed = referralFee - sum` before falling through. `settleContest`'s `if (undistributed > 0)` restore (`:365-370`) is consequently never triggered, even though `netPrimary`/`netSecondary` were already reduced by the **full** `referralFee` (`:353-356`). The shortfall is stranded balance, recoverable only via `_allocateUnallocatedBalance` — itself only reachable from the two operator-only push functions — and when recovered, it is swept as an indivisible lump into whichever single secondary position happens to still hold unclaimed shares on the winning entry (see Medium-4), not restored proportionally.

**Precondition:** `rewardCalculator` is a deployer-chosen, unvalidated constructor address (permissionless factory — see High-6). The bundled canonical `lib/referralTree` `RewardCalculator` happens to always allocate exactly (`amounts[0] += remainder`), which is precisely why the repo's own test suite (`MaliciousOverpayCalculator`, `RevertingRewardCalculator`) covers overpay and revert but has zero coverage for underpay — multiple agents independently flagged this exact test gap.

**Trace (converged across agents):** `referralNetworkBps=1000`, `totalGross=100,000e6` USDC → `referralFee=10,000e6`. A calculator returning amounts summing to 0 (or any partial amount) passes the `<=` check, transfers nothing (or partially), and returns 0 — `undistributed==0` so nothing is restored. Both pools are down 10% of TVL with the difference owned by nobody.

**Fix:** `undistributed = referralFee - sum;` before the transfer loop (one line).

---

**3. `ContestFactory.createContest` is fully permissionless and lets the _deployer_ — not the disclosed-trusted `operator` — permanently wire in a self-controlled `referralGraph`/`rewardCalculator`, extracting up to 10% of TVL with no accounting bug required**

**Severity:** High
`ContestFactory.createContest()` — `ContestFactory.sol:16-46`; `ContestController` constructor validation — `:145-153` (only non-zero checks)
**Confidence:** 92 · **Origin:** `[phase1: access-control-4, general-19]` `[phase2: trust-gap, first-principles, periphery, economic-security]`

Unlike Finding 2, this needs no under-distribution bug: a fully-honest, fully-paid-out referral distribution to an attacker-chosen `referralGraph`/`rewardCalculator` pair is enough. The contract's own trust NatSpec (`ContestController.sol:30-33`) names only `operator` as requiring off-chain trust and explicitly contrasts it with "ReferralGraph's authorized-oracle role" — implying that role is _not_ something participants must independently trust. In fact whoever calls `createContest` (need not be `operator`) fixes `referralGraph`/`rewardCalculator` forever, validated only as non-zero (`:150-151`).

**Trace:** attacker deploys `EvilGraph.getReferrer()`→attacker, `EvilGraph.getPayoutChain()`→`[attacker]`, `EvilCalc.calculateRewards()`→`[referralFee]`, naming a reputable multisig as `operator` (so the contest looks legitimate — `ContestFactory.ContestCreated` doesn't even emit the referral addresses). The operator settles an entirely honest outcome; `distributeReferralFee` passes every check (`sum == referralFee` exactly) and transfers up to `referralNetworkBps` (capped 1000 = 10%) of `totalGross` directly to the attacker.

**Fix:** Hold `referralGraph`/`rewardCalculator` (and ideally `paymentToken`) as factory-level immutables or behind a factory-curated allowlist rather than accepting them as arbitrary per-call arguments; emit every config address in `ContestCreated`.

---

**4. `entryId` is unauthenticated and caller-chosen — front-running captures another entrant's prize slot; the merkle allowlist authorizes the wrong thing**

**Severity:** High
`ContestController.addPrimaryPosition()` — `:168-184`; `PrimaryContest.validatePrimaryMerkleProof()` — `:20-29`, leaf is `keccak256(abi.encodePacked(participant))`
**Confidence:** 93 · **Origin:** `[phase1: access-control-1, general-4, erc721-1, dos-4]` `[phase2: access-control (2 findings), trust-gap, invariant lead, execution-trace lead, boundary, economic-security, first-principles]`

The merkle leaf commits to _who_ may register, never _which_ `entryId`. `entryOwner[entryId]` is pure first-come-first-served for any `uint256`, and `entryId` necessarily carries off-chain contestant identity (the operator names it in `winningEntries` at settlement). Even a fully-populated, correctly-configured allowlist does not close this — any allowlisted address can register any other allowlisted participant's intended slot.

```solidity
// PrimaryContest.sol:20-29
function validatePrimaryMerkleProof(bytes32 merkleRoot, address participant, bytes32[] calldata merkleProof) internal pure {
    if (merkleRoot != bytes32(0)) {
        bytes32 leaf = keccak256(abi.encodePacked(participant));   // entryId is NOT in the preimage
        require(MerkleProofLib.verify(merkleProof, merkleRoot, leaf), "Invalid merkle proof");
    }
}
```

**Trace:** attacker front-runs a victim's pending `addPrimaryPosition(7, proof)` with `addPrimaryPosition(7, ownProof)`; victim's tx reverts `"Entry already exists"` permanently (no reassignment path exists — only `entryOwner` may `removePrimaryPosition`). If entry 7 is later named a winner, `_payPrimaryPayout` pays the attacker, and if entry 7 is `secondaryWinner`, `entryOwner[7]` also anchors the referral-fee distribution.

**Fix:** Bind the resource into the leaf: `keccak256(abi.encodePacked(participant, entryId))`.

---

**5. Permissionless `cancelExpired()` accepts the `LOCKED` state — any losing participant can veto a decided settlement and convert a forfeited stake into a full refund**

**Severity:** High
`ContestController.cancelExpired()` — `:491-496`
**Confidence:** 94 · **Origin:** `[phase1: general-5, access-control-3, dos-12]` `[phase2: access-control, trust-gap, flow-gap, periphery, economic-security]`

```solidity
function cancelExpired() external {
    require(block.timestamp >= expiryTimestamp + SETTLEMENT_GRACE_PERIOD, "Settlement grace period active");
    require(state != ContestState.SETTLED && state != ContestState.CLOSED, "Already settled");   // LOCKED passes
    state = ContestState.CANCELLED;   // terminal — no un-cancel path anywhere in the codebase
    emit ContestCancelled();
}
```

`settleContest` requires exactly `state == LOCKED` (`:318`). `cancelExpired` also accepts `LOCKED`, is permissionless, and its target state is terminal. Once `block.timestamp >= expiryTimestamp + 1 day`, the operator's `settleContest` transaction is public in the mempool before it executes — any participant who reads it and sees they lost can front-run with `cancelExpired()`. CANCELLED refunds every primary deposit in full and every secondary position's tracked principal in full — a directed transfer from winners to losers, for the cost of one transaction, triggerable by any single loser (and in a 500-entry contest with one winner, up to 499 independently-motivated parties can trigger it).

**Fix:** Exclude `LOCKED` from `cancelExpired`'s accepted states; give a `LOCKED` contest a separate, much longer abandonment timeout instead.

---

**6. Referral-graph gas exhaustion / return-data bomb inside the settlement try/catch permanently bricks `settleContest` — empirically confirmed**

**Severity:** High
`ContestController.settleContest()` `:358-378` (`try this.distributeReferralFee`); `distributeReferralFee()` unbounded STATICCALLs at `:436/444/457`; post-decode-only truncation `:446-450`
**Confidence:** 90 · **Origin:** `[phase1: general-1 (hand-estimated), access-control-10 (unverified lead), dos-1 (empirically confirmed via forge)]`

EIP-150 gives the self-call 63/64 of remaining gas; the parent retains 1/64. `distributeReferralFee` makes two unbounded-gas STATICCALLs to a **deployer-chosen** `referralGraph` (permissionless factory — see High-3). A graph that burns gas, or returns an oversized `address[]` that costs quadratic memory-expansion before the post-decode `mstore` truncation at `:448` ever runs, forces the child to OOG; the `catch` at `:371` then has only ~1/64 of the gas to complete the remaining O(entries.length) settlement work.

**Empirically measured** (`dos` breadth agent, cold storage, actual `forge test`): settlement **reverts for OOG at `entries.length ≥ 150`**, and remains broken even at a 100,000,000 gas cap (the 63/64 split scales with whatever is supplied — no gas limit rescues it). The return-data-bomb variant measured separately: a `getPayoutChain` returning 200,000 elements pushes `settleContest` to 58.2M gas via memory-expansion cost alone, with no malicious intent required beyond a graph that ignores its own `maxLevels` argument.

**Impact:** the contest can never reach `SETTLED` — only `cancelExpired`/`cancelContest`, refunding everyone and nullifying every outcome.

**Fix:** Cap gas explicitly on the two untrusted STATICCALLs (`staticcall{gas: N}`); bound copied returndata _before_ decode rather than truncating after; reorder so the O(n) zeroing loop (`:392-396`) runs before the referral call, shrinking the post-catch tail to O(1).

---

### Medium

**7. `settleContest`'s O(n²) duplicate-winner check makes settlement gas-prohibitive at the contract's own advertised scale**

**Severity:** Medium · **Confidence:** 88 · **Origin:** `[phase1: dos-2 (empirical), general-8]`
`settleContest()` `:334-336` (nested dedup loop), `:343-346`/`:392-396` (full `entries` scans).
Empirically measured: 500 winners / 500 entries (the contract's own `MAX_ENTRIES` cap) costs **40.8M gas** — over any mainnet block limit; the contract cannot execute the maximum configuration it itself permits. Compounds with High-4's cheap entry-filling and directly tightens High-6's 1/64-gas margin.
**Fix:** replace the O(n²) dedup with an O(n) check (transient-storage seen-set, or require `winningEntries` strictly ascending).

**8. Zero `primaryDepositAmount` is never validated — free registration-slot exhaustion at zero net cost**

**Severity:** Medium · **Confidence:** 87 · **Origin:** `[phase1: dos-4 (empirical), erc20-6, general-8]` `[phase2: access-control, first-principles, boundary, economic-security]`
Constructor (`:134-166`) validates seven of nine parameters but never `_primaryDepositAmount > 0`. With a zero (or fully-refundable nonzero) deposit and no merkle root set (Medium-9's default-open window), one address can occupy all 500 `MAX_ENTRIES` slots for gas cost alone — empirically confirmed at 38.5M gas total, fully refundable via `removePrimaryPosition` while OPEN — permanently blocking every legitimate entrant with no operator eviction path.
**Fix:** `require(_primaryDepositAmount > 0)` in the constructor; add a per-address registration cap.

**9. Merkle allowlist fails open by default and is mutable in every lifecycle state with no timelock**

**Severity:** Medium · **Confidence:** 85 · **Origin:** `[phase1: general-3, access-control-2]` `[phase2: access-control]`
`ContestFactory.createContest` takes no root argument — every contest is born fully open (both roots `bytes32(0)`, `state==OPEN`). When the deployer isn't the operator, closing the allowlist requires a second, separate, publicly-visible transaction. `setPrimaryMerkleRoot`/`setSecondaryMerkleRoot` (`:480-488`) have no state gate and can be flipped to/from zero at any point, indistinguishable in the event log from a routine update.
**Fix:** pass roots through the factory into the constructor; make an unset root deny-by-default rather than allow-all.

**10. `_allocateUnallocatedBalance` sweeps surplus as an indivisible lump to whichever single position happens to still hold unclaimed shares, and the beneficiary is operator/timing-controlled**

**Severity:** Medium · **Confidence:** 84 · **Origin:** `[phase1: general-9]` `[phase2: flow-gap, numerical-gap, execution-trace lead, asymmetry lead]`

```solidity
// ContestController.sol:702-706
if (secondaryLiquidityPerEntry[secondaryWinningEntry] > 0 || netPosition[secondaryWinningEntry] > 0) {
    secondaryLiquidityPerEntry[secondaryWinningEntry] += unallocated;
```

Two independent defects, both confirmed with quantified traces: (a) the `||` should be `netPosition > 0` alone — crediting a bucket with nonzero liquidity but zero remaining supply (reachable under a balance-shortfall scenario, see High-5) makes the credit permanently unclaimable; (b) even in the ordinary case, any surplus (referral shortfall from High-2, floor-division dust, a donation) is handed 100% to whichever single holder hasn't claimed yet, and — since `pushPrimaryPayouts`/`pushSecondaryPayouts` accept empty arrays and still trigger the sweep — the _operator_ controls exactly who that is by choosing sweep timing and push order (flow-gap's trace: identical holders, identical balances, moving $100,000 of surplus entirely from one to the other purely by call ordering).
**Fix:** route swept surplus back to the pool it originated from, proportionally among all not-yet-claimed holders, rather than as a lump to one bucket; fix the `||`→`&&`.

**11. No `minTokensOut`/slippage parameter on `addSecondaryPosition` — quantified front-running transfer between ordinary users**

**Severity:** Medium · **Confidence:** 82 · **Origin:** `[phase1: erc721-10, dos-8]` `[phase2: economic-security — quantified]`
`buyerTokens` is priced live against `netPosition[entryId]` at execution with only a `> 0` floor check (`:223`). Economic-security's exact-curve trace: victim submits a $50,000 buy into an empty entry expecting 2,123.49 shares; an equal-size front-run buy first cuts the victim to 566.37 shares (−73.3%), transferring $28,944.42 of eventual redemption value to the front-runner — pure MEV, no privilege required.
**Fix:** add an explicit `minTokensOut` parameter.

**12. Fee-on-transfer / rebasing `paymentToken`: asymmetric clamp-then-burn on secondary payouts vs. no clamp at all on primary payouts**

**Severity:** Medium · **Confidence:** 83 · **Origin:** `[phase1: erc20-1/2/3, general-2]` `[phase2: execution-trace, asymmetry, boundary, economic-security, first-principles]`
Both deposit paths (`addPrimaryPosition:177-183`, `addSecondaryPosition:225-231`) credit the _requested_ amount before pulling, never measuring the delta received. Under a fee-on-transfer/deflationary token, `removeSecondaryPosition`/`_paySecondaryClaim` clamp payout to the contract's _entire_ balance (contradicting their own NatSpec, which claims per-entry-only) and then unconditionally burn the claimant's full position even at a clamped-to-zero payout; `_payPrimaryPayout` has no clamp at all and simply reverts permanently once underfunded, with no partial-claim recovery. Reduced to Medium (from the individual agents' High) because it requires a non-standard `paymentToken`, itself gated behind the same undisclosed-deployer-trust boundary as High-3/High-6 — not exploitable against a conforming ERC20.
**Fix:** measure `balanceAfter-balanceBefore` on both deposit paths; clamp `_payPrimaryPayout` symmetrically; do not destroy a position for less than its computed value.

**13. `minSecondaryPurchaseAmount`/bonding-curve constants are denominated in whole token _count_, not value — the curve is either dead or effectively unusable for any non-~$1-value `paymentToken`**

**Severity:** Medium · **Confidence:** 78 · **Origin:** `[phase2: math-precision]`
`toShareUnits` maps exactly one whole payment-token unit to `1e18` share units regardless of decimals, and `SecondaryPricing`'s `BASE_PRICE`/`COEFFICIENT` are absolute constants calibrated assuming that unit is worth ~$1. For a WBTC-denominated contest (`decimals=8`, ~$100,000/unit), the minimum secondary buy becomes $100,000 and the whale-protection "price doubles" point moves to $25.8M of entry TVL — the entire secondary layer is effectively unusable. `ContestFactory.createContest` applies no value-sanity check to `paymentToken`.
**Fix:** make the minimum purchase and curve coefficient constructor parameters validated against a sane range, or restrict the factory to an allowlist of ~$1-unit stablecoins.

---

### Low

**L1.** `removeSecondaryPosition`'s OPEN-state pro-rata branch (`:257-259`) is dead code contradicting its own NatSpec — buys require `ACTIVE` and the state machine never returns to `OPEN`, so the only live sell-back is the `CANCELLED` full-principal refund and secondary buyers have **no exit whatsoever during the entire ACTIVE phase**. **Confidence 90.** Confirmed independently by essentially every hunting agent in both phases (erc721-12, precision-math-13, general-11, access-control-8, dos-8-note in phase 1; access-control, invariant, asymmetry, periphery, boundary, first-principles, numerical-gap in phase 2 — 11+ agents). _Fix:_ delete the branch or gate ACTIVE-state sells explicitly; correct the NatSpec.

**L2.** Empty `catch {}` blocks in both push-payout trampolines swallow every failure mode including OOG, with no reason captured and no per-item failure record; the referral-fee payout loop additionally has no per-recipient isolation at all (unlike the push paths), so one blocklisted chain member forfeits the whole fee for every level. **Confidence 80.** `[phase1: general-12, dos-11, erc20-7, dos-10]` `[phase2: execution-trace, asymmetry]`. _Fix:_ capture `bytes reason` and emit a distinguishing failure event.

**L3.** `netPosition` is `int256` used as an unsigned supply counter: 5+ unguarded `uint256(netPosition[...])` casts, 3 separate writers (one bypassing the shared library helper and its `SecondaryPositionSold` event). **Confidence 75** — verified unreachable today (the mint/burn pairing invariant holds), reported as defense-in-depth. `[phase1: erc721-8/9, precision-math-11, general-13/18]` `[phase2: invariant, numerical-gap]` all independently confirmed non-exploitable but worth hardening. _Fix:_ change to `uint256`; route the inline write through the library helper.

**L4.** `calculateTokensFromCollateral`'s 50-iteration bisection cap is insufficient to converge (needs ~61+ for realistic bracket widths) — buyers are systematically under-minted by a bounded, non-exploitable residual (~1.8e-15 relative). **Confidence 80.** `[phase1: precision-math-1]` `[phase2: boundary, math-precision, numerical-gap]` all independently re-derived and confirmed the same magnitude. _Fix:_ raise the cap to 256, or rely purely on the convergence break condition.

**L5.** `calculatePrice`'s `/1e18` floor under-charges every buyer by ≤0.5ppm, diluting existing holders one-directionally; the accompanying code comment claiming the flat-price region is `shares < 1e9` is wrong by 8 orders of magnitude (actual threshold ≈0.258 shares). **Confidence 78.** `[phase1: precision-math-2/3]` `[phase2: math-precision]`. _Fix:_ compute the integral in closed form on the un-truncated cubic.

**L6.** Per-winner primary payout floors independently with no remainder sweep (up to `numWinners-1` wei stranded), inconsistent with the zero-supply spill loop 20 lines below which _does_ sweep its exact remainder. **Confidence 75.** `[phase1: precision-math-5]` `[phase2: math-precision, asymmetry]`. _Fix:_ mirror the spill loop's `distributed` accumulator.

**L7.** Zero-supply spill credits `primaryPrizePoolPayouts` without a matching `primaryPrizePool +=`, breaking `primaryPrizePool == Σ payouts`; masked by a saturating (not reverting) clamp in `_payPrimaryPayout`. No fund loss — `outstandingClaimableLiabilities` correctly reads `primaryPrizePoolPayouts`, not the drifted `primaryPrizePool`. **Confidence 85** (exceptionally well corroborated as accounting-only). `[phase1: general-6, precision-math-6]` `[phase2: invariant, execution-trace, asymmetry, math-precision, numerical-gap — 5 independent leads, all reaching the identical conclusion]`. _Fix:_ credit `primaryPrizePool` alongside the spill payouts; replace the saturating clamp with a plain subtraction so future drift reverts loudly.

**L8.** `distributeReferralFee`'s referral-loop has no zero-address/self-address check on `chain[i]` recipients, and no per-recipient isolation (see L2). **Confidence 70.** `[phase1: erc20-7]`.

**L9.** No lower bound on `paymentToken.decimals()` — BPS carves, subsidy splits, and pro-rata payouts round to zero for ≤2-decimal tokens. **Confidence 78.** `[phase1: erc20-8/10, precision-math-9, general-20]` `[phase2: numerical-gap-lead]`. _Fix:_ `require(paymentTokenDecimals >= 6 && <= 18)`.

**L10.** `SafeTransferLib`'s lack of a code-existence check on `paymentToken` is currently masked only incidentally by the constructor's `decimals()` probe. **Confidence 72.** `[phase1: erc20-9, general-20]`.

**L11.** Losing-entry ERC1155 shares are permanently unburnable post-settlement; `netPosition` (shadow total-supply) is never reset for non-winning entries. **Confidence 73.** `[phase1: erc721-7, general-24]`.

**L12.** `supportsInterface` advertises full ERC1155 (transfer + metadata interfaces) while every transfer function reverts and `uri()` always returns `""`. **Confidence 70.** `[phase1: erc721-2/3]`.

**L13.** Contract accounts without `onERC1155Received` are permanently locked out of the secondary market; entirely untested (0 hits across all 9 test files for the callback). **Confidence 75.** `[phase1: erc721-4]`.

**L14.** Self-call trampolines (`distributeReferralFee`, `payPrimaryPayoutExternal`, `paySecondaryClaimExternal`) don't independently re-validate the state/scope preconditions their sole external callers already enforce. Verified `msg.sender==address(this)` is unforgeable today (no delegatecall, no attacker-controlled low-level call) — defense-in-depth only. **Confidence 70.** `[phase1: access-control-7]` `[phase2: execution-trace, economic-security lead]`.

**L15 (unverified LEAD-derived).** `type(uint256).max` "transfer whole balance" token semantics (Comet/cUSDCv3-style) are traced as blocked by curve-math overflow on the secondary path; theoretically reachable on the primary path only via a self-defeating misconfiguration. **Confidence 55.** `[phase1: erc20-11]`.

**L16.** `nonReentrant` is not the first modifier on `settleContest`/`pushPrimaryPayouts`/`pushSecondaryPayouts` — inert today since `onlyOperator` makes no external call. **Confidence 65.** `[phase1: general-15]`.

**L17.** Library state-machine guards (`PrimaryContest`/`SecondaryContest`) compare against bare integer literals decoupled from the `ContestState` enum the controller itself owns — any future enum reordering silently repoints every guard. **Confidence 70.** `[phase1: general-14]` `[phase2: periphery]`.

**L18.** `ContestFactory` uses plain `CREATE` (reorg-unstable addresses) with an unpinned `^0.8.20` compiler and `evm_version=cancun`, narrowing deployable/reproducibly-verifiable chains. **Confidence 65.** `[phase1: general-21]`.

**L19 (unverified LEAD).** The `mstore(chain, MAX_REFERRAL_PAYOUT_LEVELS)` length-truncation's correctness under `via_ir` with an unpinned compiler was not independently verified (submodules absent in the sandbox). Failure mode appears bounded by the existing length-mismatch `require`. **Confidence 45.** `[phase1: general-22]`.

**L20.** `MAX_ENTRIES`/registration-DoS variants beyond L8's zero-deposit case, and the `_allocateUnallocatedBalance` dead-supply-bucket sub-case of Medium-10, requiring a balance-reducing token to reach — consolidated here to avoid double-counting against Medium-10/Medium-12. **Confidence 60.**

---

## Informational

- **`_paySecondaryClaim` sequential-claim floor residuals verified non-compounding.** `[phase1: precision-math-7]` `[phase2: invariant, numerical-gap, math-precision]` — proven the redemption ratio is monotonically non-decreasing across sequential claims and the last claimant sweeps the exact remainder.
- **`_splitPrimaryDeposit`/`_splitReferralFeeRestore` verified remainder-safe by construction** — the pattern L6/L7 should have adopted elsewhere.
- **ERC777/hook-token reentrancy analyzed exhaustively across both phases, found closed.** Every guarded entrypoint shares one `nonReentrant` lock; the self-call trampolines are gated by an unforgeable `msg.sender==address(this)`; CEI ordering verified correct at every payout site.
- **`SecondaryPricing` curve numerics verified sound at realistic scale.** Simpson's rule is exact for the underlying quadratic; overflow thresholds require token amounts far beyond any real supply; `COEFFICIENT=15` produces real, measured whale-friction.
- **"Late buyers on the winning entry redeem less than they paid" is standard bonding-curve tokenomics, not a defect** — demoted from a phase-2 finding after reconciliation; this is the intended early-buyer-advantage mechanism of any convex bonding curve, not a code bug.
- **`_removeActiveEntry` swap-pop verified O(1) and correct in all cases**, including simultaneous last-element/removal-target overlap.
- **No double-claim possible on either payout path; every withdraw path verified to fully reverse its paired deposit's state writes.**
- **Dead code and duplicated constants/events** across `ContestController` and its two inlined libraries (`processClaimPrimaryPayout` unused, `PRICE_PRECISION` duplicated, events declared twice with only one side emitting). No security impact.
- **`docs/SecondaryPricingTuning.md` is stale for 3 of 6 calibration gates** (`FrontRunCost` off by 2.7×) — the deployed `COEFFICIENT=15` still passes all six gates; only the documentation's numbers are wrong.
- **`pushPrimaryPayouts`/`pushSecondaryPayouts` carry ~2.35M gas of fixed per-call overhead** from `_allocateUnallocatedBalance`'s liability scan; batching verified retry-safe/idempotent — pure gas waste, not a DoS.

---

## Leads (unscored — plausible, not independently confirmed to a reportable confidence)

- **Deployer-controlled `referralGraph` as a selective settlement veto** — could the deployer observe the operator's proposed `secondaryWinner` (visible inside `distributeReferralFee`'s own call) and gas-bomb settlement _only_ for outcomes it dislikes, effectively vetoing the operator's choice? Traced as plausible but unverified whether 1/64 of remaining gas is ever sufficient at small `entries.length`, and whether the fallback (contest expires into `cancelExpired` refunds) is the only reachable impact for small contests. `[phase2: trust-gap]`
- **CANCELLED-state liability undercount** — `removePrimaryPosition` in `CANCELLED` pops an entry out of `entries[]` via swap-pop while its `secondaryLiquidityPerEntry` remains owed to still-active secondary holders; `outstandingClaimableLiabilities()`'s CANCELLED branch undercounts by that entry's liquidity. Refunds still work via per-user tracked principal, so no fund-loss path was found — flagged for any future code that trusts this view in CANCELLED. `[phase1: erc20-4 note]` `[phase2: asymmetry, first-principles, boundary — 3 independent confirmations, all inconclusive on impact]`

---

> ⚠️ This review was performed by an AI-orchestrated three-phase audit pipeline (context building → breadth checklists → depth attacker-mindset agents → hybrid reconciliation). AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. A human security review, a public bug bounty, and on-chain monitoring are strongly recommended before this contract handles material value — particularly given the Critical finding above, which does not require any privileged access to exploit.
