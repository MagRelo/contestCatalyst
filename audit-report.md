# Security Audit Report — contestCatalyst (ContestController)

**Client engagement**: leftclaw job #391 — "recent changes to payouts, particularly with
referrals & payouts; check for bad states, orphaned funds, operational headaches"

**Target**: [`MagRelo/contestCatalyst`](https://github.com/MagRelo/contestCatalyst)
**Commit audited**: `d24958ce478a11c896193e1f1b475bf7708207ed`
**Submodule in scope**: `lib/referralTree` (core payouts/referrals logic) @
`e81f78b082c7b7287433e7cf5589051ae36efa3b` — [`MagRelo/referralTree`](https://github.com/MagRelo/referralTree)

**Files in scope**:

- `src/ContestController.sol`, `src/ContestFactory.sol`, `src/PrimaryContest.sol`,
  `src/SecondaryContest.sol`, `src/SecondaryPricing.sol`
- `lib/referralTree/src/core/ReferralGraph.sol`, `lib/referralTree/src/core/RewardCalculator.sol`
  (and their interfaces) — included because the client's brief specifically targets the
  referral/payout integration, which lives partly in this dependency, not just in
  `ContestController`. This is a scope call made explicit here: standard `lib/` exclusion
  was overridden for this one first-party dependency, co-maintained by the same author.

**Methodology**: three-phase audit — Phase 0 (protocol map, access-control inventory,
threat catalog; no findings) → Phase 1 breadth (7 parallel checklist domains: general,
precision-math, ERC20, ERC1155, access-control, DoS, flashloans/economics) → Phase 2
depth (12 parallel attacker-mindset agents, blind to Phase 1's findings) → hybrid
reconciliation with a coverage gate against the Phase-0 inventory/catalog. All 23
external/public state-changing entrypoints in scope were examined by multiple
independent agents across both phases; every citation below was independently
re-verified against the source files listed above before this report was finalized.

**Reconciliation summary**: Overlap (found independently by both phases): 9 · Phase-1-only:
7 · Phase-2-only: 3 · Coverage holes closed this pass: 0 (both phases' 19 combined agents
already covered every privileged/value-moving entrypoint and every threat-catalog row).

**Severity definitions**: **Critical** = direct loss of funds by a third party, no
preconditions. **High** = loss of funds requiring specific conditions, or permanent DoS.
**Medium** = degraded behavior, trust-model violation, incorrect accounting, or
owner-only fund loss. **Low** = best-practice violation, latent bug, or confusing
behavior without direct fund risk. **Info** = no security impact.

---

## Findings Summary

| #   | Title                                                                                                   | Severity     | Confidence |
| --- | ------------------------------------------------------------------------------------------------------- | ------------ | ---------- |
| 1   | Last winning-entry secondary claimant sweeps the entire contract balance                                | **Critical** | 98         |
| 2   | Removing a primary position orphans that entry's secondary-market funds                                 | **High**     | 95         |
| 3   | Settlement is front-runnable while the secondary market is still open                                   | **High**     | 82         |
| 4   | `cancelExpired()` is permissionless and can permanently block settlement                                | **High**     | 90         |
| 5   | Unbounded `entries[]` can permanently brick both settlement and the close escape hatch                  | **High**     | 75         |
| 6   | Unvalidated `rewardCalculator` return values let a malicious dependency drain the contract              | Medium       | 78         |
| 7   | No `try/catch` on referral-settlement external calls — one bad dependency permanently blocks settlement | Medium       | 78         |
| 8   | A separate, uncoupled trust domain can redirect the referral fee via pre-emptive registration           | Medium       | 72         |
| 9   | `closeContest()` can sweep already-settled, unclaimed winner payouts to the oracle                      | Medium       | 82         |
| 10  | Duplicate/non-member `winningEntries` silently strand primary payout funds                              | Medium       | 78         |
| 11  | Bonding-curve "whale protection" is dead code for all realistic deposit sizes                           | Medium       | 88         |
| 12  | Fee-on-transfer / rebasing `paymentToken` breaks accounting assumptions                                 | Medium       | 68         |
| 13  | `claimSecondaryPayout` vs `pushSecondaryPayouts` residual-handling asymmetry                            | Low          | 80         |
| 14  | `pushPrimaryPayouts` reverts the whole batch on one stale `entryId`                                     | Low          | 88         |
| 15  | `pushSecondaryPayouts` reverts the whole batch on one blocklisted recipient                             | Low          | 82         |
| 16  | `secondaryDepositedPerEntry` goes stale on ERC1155 transfer                                             | Low          | 88         |
| 17  | `_mint` fires before the payment pull in `addSecondaryPosition` (CEI violation)                         | Low          | 78         |
| 18  | `addSecondaryPosition` has no expiry check (inconsistent with the primary path)                         | Low          | 82         |
| 19  | `ReferralGraph` ownership is one-step and transferable to `address(0)`                                  | Low          | 80         |
| 20  | Contest `oracle` is an immutable single point of failure with no pause                                  | Low          | 75         |
| 21  | Referral-tree cycles produce duplicate recipients in `getPayoutChain`                                   | Info         | 65         |
| 22  | `uri()` always returns empty despite advertising ERC1155 metadata support                               | Info         | 90         |

**Leads** (plausible, confidence < 50, not confirmed as exploitable): the bonding-curve
binary search's initial lower bound is unverified and could in principle over-mint
shares in the curve's steep region — but Finding 11 establishes that region requires
~1e21 shares, practically unreachable for any realistic token/deposit size, so this is
recorded as a low-confidence lead rather than a finding.

---

## Access-Control Inventory

**Three independent privilege domains**, never coupled on-chain:

| Domain                                                  | Grant / revoke                                                                                                                | Unlocks                                                                                                                                                                                                                  |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ContestController.oracle` (immutable)                  | Constructor-only, chosen unconstrained by whoever calls `ContestFactory.createContest`; **no transfer or renounce mechanism** | `activateContest`, `lockContest`, `settleContest`, `cancelContest`, `closeContest`, `setPrimaryMerkleRoot`, `setSecondaryMerkleRoot`, `pushPrimaryPayouts`, `pushSecondaryPayouts`; also the fee/dust fallback recipient |
| `ReferralGraph.owner` (solmate `Owned`)                 | Constructor; one-step `transferOwnership`, no zero-address guard                                                              | `authorizeOracle`, `unauthorizeOracle`                                                                                                                                                                                   |
| `ReferralGraph._authorizedOracles[groupId]` (per-group) | Granted/revoked by `owner`                                                                                                    | `register`, `batchRegister`, `setSkiplisted` — scoped to that `groupId`                                                                                                                                                  |

**Unguarded state-changing entrypoints** (callable by anyone):

- `ContestController.cancelExpired()` — see Finding 4.
- `addPrimaryPosition` / `addSecondaryPosition` — open by design whenever the respective
  merkle root is unset (`bytes32(0)`).
- `ContestFactory.createContest(...)` — no validation on any constructor argument.
- Standard ERC1155 `setApprovalForAll` / `safeTransferFrom` / `safeBatchTransferFrom` —
  shares are freely transferable at any contest state.

All `ReferralGraph` state-changing functions are correctly gated (owner or per-group
authorized oracle); none are arbitrary-caller reachable.

## Threat Model

| Actor                                                               | Reaches                                                                                       | Could gain                                          | Status                   |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | --------------------------------------------------- | ------------------------ |
| Any address                                                         | `cancelExpired()`                                                                             | Permanently block settlement post-expiry            | **Finding 4**            |
| Any address                                                         | Free registration flood (if `primaryMerkleRoot` unset and `primaryDepositAmount` unvalidated) | Grow `entries[]` to brick settlement/close          | **Finding 5**            |
| Secondary-market participant / last claimant                        | `claimSecondaryPayout` dust-sweep tail                                                        | Entire contract balance, not just fair share        | **Finding 1** (headline) |
| Any entry-owner                                                     | `removePrimaryPosition` while secondary positions exist                                       | Strand other users' funds (or accidentally does so) | **Finding 2**            |
| Well-capitalized actor watching the mempool                         | `addSecondaryPosition` during `ACTIVE`, ahead of `settleContest`                              | Capture losing-side merged liquidity risk-free      | **Finding 3**            |
| Contest deployer (`ContestFactory.createContest`, unrestricted)     | Chooses `oracle`, `referralGraph`, `rewardCalculator`, `referralGroupId`                      | Full control of a given contest's trust surface     | **Findings 6, 7**        |
| `ReferralGraph` per-group authorized-oracle (separate trust domain) | Pre-register an unregistered future winner under an attacker referrer                         | Redirect referral fee                               | **Finding 8**            |
| `ContestController.oracle`                                          | `closeContest` post-SETTLED                                                                   | Unclaimed winner payouts                            | **Finding 9**            |

**Invariants checked and confirmed holding** (no finding): settlement's fee/net BPS
sizing always floors in the safe direction (`referralFee + netPrimary + netSecondary ≤
totalGross`, at most ~2 wei retained by the contract, never over-committed); the
zero-supply spill loop conserves the redistributed pool exactly; `netPosition[entryId]`
cannot go negative given every decrement is bounded by an actual burned ERC1155
balance; self-referral is blocked (`SelfReferralNotAllowed`); a pure OPEN-state
buy-then-sell round trip on the bonding curve nets zero (no same-transaction arbitrage);
bounded loops (skiplist/oracle-list swap-pop removal, the 50-iteration pricing binary
search) are not attacker-forceable into unbounded work.

---

## Findings

### 1. Last winning-entry secondary claimant sweeps the entire contract balance

**Severity**: Critical · **Confidence**: 98 · **Origin**: `[both]` — independently found
by 4 of 7 Phase-1 agents and 11 of 12 Phase-2 agents; verified directly against source
for this report.
**Location**: `ContestController.claimSecondaryPayout()`, `src/ContestController.sol:298-304`

```solidity
if (uint256(netPosition[entryId]) == 0) {
    uint256 remaining = IERC20Balance(paymentToken).balanceOf(address(this));
    if (remaining > 0) {
        secondaryLiquidityPerEntry[entryId] = 0;
        SafeTransferLib.safeTransfer(ERC20(paymentToken), msg.sender, remaining);
    }
}
```

**Description**: After paying a claimant their fair pro-rata share of `secondaryLiquidityPerEntry[entryId]` (L274, L286-296), this tail is meant to sweep leftover rounding dust once an entry's ERC1155 supply reaches zero. Instead of bounding the sweep to this entry's own residual, `remaining` reads `paymentToken.balanceOf(address(this))` — the contract's **entire** live balance. The contract commingles the unclaimed primary prize pool (`primaryPrizePool` / `primaryPrizePoolPayouts`, set at settlement, L386-391, physically still held until each winner calls `claimPrimaryPayout`) with every entry's secondary liquidity in one balance. Whoever's claim happens to bring `netPosition[entryId]` to zero — fully within the claimant's own control, since claim timing and share acquisition are permissionless — receives the entire remaining balance, including funds owed to unrelated primary winners.

**Proof of Concept** (values from independently-converging agent traces, verified against the code above):

1. Two primary entries deposit 100 each (no subsidy) → `primaryPrizePool = 200`, held in the contract.
2. Attacker buys secondary shares on the entry that will win — a purchase as small as a few wei is sufficient (`SecondaryPricing.calculatePrice` prices at a flat `BASE_PRICE` for any realistic supply — see Finding 11), becoming the sole or last holder.
3. Oracle settles with that entry as sole winner: `primaryPrizePoolPayouts[winner] = 200` (unclaimed), `secondaryLiquidityPerEntry[winner] = netSecondary` (merged). Contract balance = 200 + netSecondary.
4. Attacker calls `claimSecondaryPayout(winner)`: receives their fair pro-rata `netSecondary`; the burn brings `netPosition[winner]` to 0; the tail then reads `remaining = balanceOf(this) = 200` (the untouched primary pool) and transfers it entirely to the attacker.
5. The primary winner's subsequent `claimPrimaryPayout` reverts — `safeTransfer` fails against a drained balance (this path has no balance clamp, L179-194). Their earned prize is gone.

**Recommendation**: Bound the sweep to this entry's own tracked residual — `min(remaining, <this entry's pre-payout secondaryLiquidityPerEntry>)` captured before the pro-rata transfer — never `balanceOf(address(this))`. Simplest fix: delete the whole-balance tail entirely, matching `pushSecondaryPayouts` (L499-536), which computes the identical entitlement with no such tail, and route any genuine residual dust through `closeContest` instead.

---

### 2. Removing a primary position orphans that entry's secondary-market funds

**Severity**: High · **Confidence**: 95 · **Origin**: `[both]` — independently found by
1 Phase-1 agent and 9 of 12 Phase-2 agents; verified directly against source.
**Location**: `ContestController.removePrimaryPosition()`, `src/ContestController.sol:165-177`;
guards in `src/SecondaryContest.sol:55` (`validateRemoveSecondaryPosition`) and
`src/SecondaryContest.sol:71` (`validateClaimSecondaryPayout`)

**Description**: `removePrimaryPosition` (allowed while `state == OPEN` or `CANCELLED`) zeroes `entryOwner[entryId]` and swap-pops the entry out of `entries[]`, but never checks or reconciles `netPosition[entryId]` / `secondaryLiquidityPerEntry[entryId]`. Since secondary buys are permitted while `OPEN` (`SecondaryContest.sol:39`, states 0 or 1), an entry can hold real secondary liquidity — other users' deposited funds — when its owner removes their primary position. After removal:

- `removeSecondaryPosition` reverts: `SecondaryContest.sol:55` requires `entryOwner[entryId] != address(0)`.
- `claimSecondaryPayout` reverts: `SecondaryContest.sol:71` requires the same, and the entry — no longer in `entries[]` — can never become `secondaryWinningEntry`.
- `settleContest`'s TVL/merge loops (`src/ContestController.sol:339-342`, `:396-400`) iterate only `entries[]`, so this liquidity is never merged, never zeroed, and simply sits in the contract, recoverable only via `closeContest`'s sweep — to the oracle, not to the rightful depositors.

**Proof of Concept**:

1. `OPEN` state. Alice registers entry 7 via `addPrimaryPosition`.
2. Bob calls `addSecondaryPosition(7, 500, ...)` → `secondaryLiquidityPerEntry[7] = 500`, `netPosition[7] > 0`, Bob holds ERC1155 shares for id 7.
3. Alice calls `removePrimaryPosition(7)` — passes (`OPEN`, she owns entry 7) — gets her full deposit refunded, `entryOwner[7] = 0`, entry 7 popped from `entries[]`.
4. Bob calls `removeSecondaryPosition(7, ...)` → reverts `"Entry does not exist"`. He can never claim either (entry 7 can never be the settled winner). His 500 is permanently locked.

This is reachable either as an ordinary contestant's honest exit or as deliberate griefing by any entry owner against secondary bettors on their own entry, at zero cost to the remover.

**Recommendation**: In `removePrimaryPosition`, require `netPosition[entryId] == 0` (no outstanding secondary shares) before allowing removal, or unwind/refund the entry's secondary liquidity to its holders as part of the same transaction.

---

### 3. Settlement is front-runnable while the secondary market is still open

**Severity**: High · **Confidence**: 82 · **Origin**: `[both]` — Phase-1's flashloans/economics
agent and Phase-2's economic-security agent independently produced closely-matching
quantified simulations.
**Location**: `ContestController.settleContest()` state gate, `src/ContestController.sol:325`;
`addSecondaryPosition()` state gate, `src/SecondaryContest.sol:39`; merge, `src/ContestController.sol:396-401`

**Description**: `settleContest` accepts `state == ACTIVE` as well as `LOCKED` (L325). `addSecondaryPosition` is still open during `ACTIVE` (`SecondaryContest.sol:39` allows states 0 or 1). The winning entry is revealed the instant the oracle's `settleContest` transaction is visible (mempool, or simply predictable from off-chain event resolution). An attacker can buy heavily into the soon-to-be-winning entry immediately before settlement lands — cheaply, because the bonding curve prices near-flat for any realistic supply (Finding 11) — acquiring a large share of `netPosition[winningEntry]` moments before every losing entry's secondary liquidity is merged into that entry's slot (L396-401). The attacker then claims post-settlement, capturing a share of capital contributed by bettors who took genuine market risk, while the attacker took essentially none.

**Proof of Concept** (from the independent economic-security simulation): a losing entry holds 5,000 (token units) of honest secondary liquidity; the winning entry holds only 500 pre-attack. An attacker front-runs the visible settlement transaction with a 5,000-unit buy into the winning entry (near 1:1 due to the flat curve). Post-merge the combined pool is 10,500; the attacker's now-dominant share lets them redeem ~9,545, a ~4,545 profit for one block of capital exposure — cutting the legitimate winning-side holders' payout from an expected 5,500 down to ~954.

**Recommendation**: Require `state == LOCKED` (not `ACTIVE`) in `settleContest`, ensuring secondary buys (already blocked in `LOCKED`) are provably closed before the winner can be known. Consider also enforcing a minimum delay between `lockContest` and `settleContest`, and/or a minimum holding period before a secondary position is eligible for `claimSecondaryPayout`.

---

### 4. `cancelExpired()` is permissionless and can permanently block settlement

**Severity**: High · **Confidence**: 90 · **Origin**: `[both]` — 1 Phase-1 agent, 4 of 12
Phase-2 agents (2 as FINDING, 2 corroborating as LEAD); verified directly against source.
**Location**: `ContestController.cancelExpired()`, `src/ContestController.sol:459-464`

```solidity
function cancelExpired() external {
    require(block.timestamp >= expiryTimestamp, "Not expired");
    require(state != ContestState.SETTLED && state != ContestState.CLOSED, "Already settled");
    state = ContestState.CANCELLED;
    emit ContestCancelled();
}
```

**Description**: Unlike every other lifecycle transition (`activateContest`, `lockContest`, `settleContest`, `cancelContest`, `closeContest` — all `onlyOracle`), this function has **no caller guard** at all — only a timestamp and state check. Once `expiryTimestamp` passes, any address can flip an `ACTIVE` or `LOCKED` contest to `CANCELLED`. Because `settleContest` requires `state == ACTIVE || LOCKED` (L325) and there is no CANCELLED→SETTLED transition anywhere in the contract, this permanently and irreversibly blocks settlement. Every participant — including the actual winners — is forced onto the refund path (`removePrimaryPosition`/`removeSecondaryPosition`, both valid in `CANCELLED`) instead of receiving their earned prize distribution.

**Proof of Concept**: Contest is `ACTIVE`; the underlying event has resolved and the oracle's `settleContest` transaction is pending (in the mempool, or simply not yet submitted) at or after `expiryTimestamp`. Any losing participant — who would receive nothing at settlement but a full principal refund under cancellation — calls `cancelExpired()`. State becomes `CANCELLED`; the oracle's subsequent `settleContest()` reverts with `"Contest not active or locked"`, permanently. No fund theft occurs, but the intended winner-payout outcome is destroyed by an unprivileged third party with no cost beyond gas.

**Recommendation**: Gate `cancelExpired()` behind `onlyOracle`, or — if a permissionless safety valve is intentional for the case where the oracle disappears — restrict it to states where settlement was never realistically imminent (e.g., only `OPEN`), or add a grace window that gives the oracle settlement priority for some period after expiry before the permissionless path unlocks.

---

### 5. Unbounded `entries[]` can permanently brick both settlement and the close escape hatch

**Severity**: High · **Confidence**: 75 · **Origin**: `[phase1: dos, general]`
**Location**: `ContestController.settleContest()`, `src/ContestController.sol:339-342` and
`:396-400`; `closeContest()`, `src/ContestController.sol:437-441`; constructor,
`src/ContestController.sol:116-146` (no nonzero check on `primaryDepositAmount`)

**Description**: `entries[]` grows unbounded via `addPrimaryPosition`, with no cap on entry count. `settleContest` iterates the full array twice (TVL summation, then the zero-out/merge pass); `closeContest` iterates it once more before its sweep. Past some entry count, both exceed the block gas limit. Critically, `closeContest` — the intended fallback if settlement can't proceed — shares the same unbounded loop, so there is no recovery path once the array is large enough: the contest is stuck in `ACTIVE`/`LOCKED` forever, and even the oracle's emergency sweep cannot run. The constructor never requires `primaryDepositAmount > 0`; combined with an unset `primaryMerkleRoot` (which permits open registration), this flooding can be free.

**Proof of Concept**: Deploy with `primaryDepositAmount = 0` and no merkle root. Any address can call `addPrimaryPosition` repeatedly with distinct `entryId`s at zero token cost (gas only). Each entry adds roughly 2-3 cold storage operations to each of the two `settleContest` loops and one to the `closeContest` loop; at a large enough entry count (low thousands, depending on the deployment chain's block gas limit) both `settleContest` and `closeContest` revert on out-of-gas, with no way to shrink `entries[]` back down (removal is only self-service via `removePrimaryPosition`, one entry at a time, itself gas-bounded per call but requiring the attacker's own cooperation to reverse).

**Recommendation**: Require `primaryDepositAmount > 0` in the constructor to remove the free-flooding vector. More fundamentally, cap `entries.length` in `addPrimaryPosition`, and/or restructure settlement and close to avoid full-array iteration (e.g., accumulate `totalSecondary` incrementally on add/remove rather than summing at settle time), so gas cost never scales with historical entry count.

---

### 6. Unvalidated `rewardCalculator` return values let a malicious dependency drain the contract

**Severity**: Medium · **Confidence**: 78 · **Origin**: `[both]` — 1 Phase-1 agent (as part
of a broader referral-fragility finding), 3 of 12 Phase-2 agents as a distinct FINDING
with a concrete drain trace.
**Location**: `ContestController.settleContest()`, `src/ContestController.sol:369-376`

```solidity
uint256[] memory amounts =
    IRewardCalculator(rewardCalculator).calculateRewards(referralFee, chain.length);
for (uint256 i = 0; i < chain.length; i++) {
    if (amounts[i] > 0) {
        SafeTransferLib.safeTransfer(ERC20(paymentToken), chain[i], amounts[i]);
    }
}
```

**Description**: `rewardCalculator` is a construction-time address chosen without any validation by whoever calls `ContestFactory.createContest` (the constructor only checks non-zero, `src/ContestController.sol:133`). The transfer loop trusts the returned `amounts` array completely: it never checks `amounts.length == chain.length`, and never checks `Σamounts <= referralFee`. The honest `RewardCalculator` (`lib/referralTree/src/core/RewardCalculator.sol`) caps recipients at 10 and forces an exact sum via a remainder-to-index-0 adjustment (L45-51) — but the controller has no way to enforce that a _substituted_ calculator behaves the same way. `referralNetworkBps` is capped at 1000 (≤10%, `src/ContestController.sol:129`), giving participants a visible on-chain guarantee that is not actually backed by code: a non-conforming `rewardCalculator` can return amounts summing to far more than `referralFee` — up to the entire contract balance.

**Proof of Concept**: A contest is deployed (by a malicious or careless integrator) with a `rewardCalculator` that, given any `(referralFee, chain.length)`, returns `[balanceOf(this)]` regardless of the requested fee. Participants deposit normally, seeing only `referralNetworkBps ≤ 1000` on-chain. At settlement, if the winner's referral chain resolves to at least one address, the loop transfers the full contract balance to `chain[0]` — a complete drain, despite the advertised ≤10% cap.

**Recommendation**: After the loop (or before transferring), compute `Σamounts` and `require(sum <= referralFee)`; also `require(amounts.length == chain.length)` before indexing.

---

### 7. No `try/catch` on referral-settlement external calls — one bad dependency permanently blocks settlement

**Severity**: Medium · **Confidence**: 78 · **Origin**: `[both]` — 4 of 7 Phase-1 agents, 4+
of 12 Phase-2 agents (mostly as corroborating LEADs on the same root cause).
**Location**: `ContestController.settleContest()`, `src/ContestController.sol:358-376`
(`getReferrer`, `getPayoutChain`, `calculateRewards`, and the transfer loop)

**Description**: When `referralFee > 0`, settlement makes three external calls — to `referralGraph.getReferrer`, `referralGraph.getPayoutChain`, and `rewardCalculator.calculateRewards` — plus a variable-length transfer loop, all with **no `try/catch` anywhere** in the function. Any revert in any of these — a reverting dependency, an EOA where a contract was expected (empty-returndata ABI-decode failure), a blocklist-token transfer to any address in the resolved referral chain, or an `amounts` array shorter than `chain.length` (out-of-bounds revert) — reverts the entire `settleContest` call. Because there is no alternative settlement path, this permanently blocks the contest from ever reaching `SETTLED`, and therefore blocks every downstream claim (`claimPrimaryPayout`, `claimSecondaryPayout`, both push-payout functions).

**Proof of Concept**: Deploy with `paymentToken = USDC` and `referralNetworkBps > 0`. If any address in the winning entry-owner's resolved referral chain is later placed on USDC's blocklist (a real-world event outside the protocol's control), the `safeTransfer` at L373 reverts for that recipient, and with no `try/catch`, the entire settlement transaction reverts — every retry hits the identical revert, permanently.

**Recommendation**: Wrap the referral-fee resolution and distribution in `try/catch`, falling back to paying the fee to `oracle` on any failure (mirroring the existing `chain.length == 0` fallback at L365-367). Separately, re-cap the returned `chain.length` against `MAX_REFERRAL_PAYOUT_LEVELS` on the controller's own side rather than trusting the callee to self-enforce it.

---

### 8. A separate, uncoupled trust domain can redirect the referral fee via pre-emptive registration

**Severity**: Medium · **Confidence**: 72 · **Origin**: `[both]` — 1 Phase-1 agent, 1 Phase-2
agent (access-control), each with an independent concrete trace.
**Location**: `ContestController.settleContest()`, `src/ContestController.sol:358`
(`getReferrer`); `ReferralGraph.register()`, `lib/referralTree/src/core/ReferralGraph.sol:233`,
`_register`, `lib/referralTree/src/core/ReferralGraph.sol:208-222`

**Description**: The referral fee's recipients are determined entirely by `ReferralGraph._referrers[referralGroupId]`, writable only by that group's `_authorizedOracles` — a role granted by `ReferralGraph.owner`, a trust domain completely independent of and unaccountable to the contest's own `oracle`. If a contest's winning entry-owner has not yet registered a referrer in `referralGroupId` by the time of settlement, the graph's authorized-oracle for that group can register them under an attacker-controlled referrer chain before settlement runs, redirecting up to `referralNetworkBps` (≤10%) of the contest's combined TVL to addresses of their choosing instead of the `oracle` fallback. This requires holding the group's authorized-oracle role — itself a privileged position — so this is a cross-trust-domain risk rather than an openly permissionless one; it is real precisely because nothing on-chain ties the two roles together or requires the winner to have pre-registered.

**Proof of Concept**: Contest deployed with `referralNetworkBps = 1000` (max) and some `referralGroupId`. The public entry-owner addresses are all readable on-chain. Before settlement, the group's authorized-oracle calls `register(evilRoot, REFERRAL_ROOT, groupId)` (passes: `REFERRAL_ROOT` bypasses the "referrer must be in tree" check), then `register(winner, evilRoot, groupId)` for the not-yet-registered eventual winner (passes: `evilRoot` is now in the tree). At settlement, `getReferrer(winner)` resolves to `evilRoot`, and the fee routes to the attacker's chain instead of falling back to `oracle`. Note this specific path only works against a winner who has not already registered a legitimate referrer — `_register` reverts on `UserAlreadyRegistered`.

**Recommendation**: Document this as an explicit trust dependency at deployment time (the `referralGraph`'s owner/authorized-oracles must be trusted by the contest operator). Consider validating at construction that the graph's authorized-oracle for `referralGroupId` matches an expected address, or snapshotting the referrer relationship at `lockContest` time rather than reading it live at settlement.

---

### 9. `closeContest()` can sweep already-settled, unclaimed winner payouts to the oracle

**Severity**: Medium · **Confidence**: 82 · **Origin**: `[both]` — 1 Phase-1 agent, 9 of 12
Phase-2 agents (all consistently as LEAD rather than FINDING, reflecting the
oracle-is-a-trusted-role caveat — recorded here as a reportable Medium given the
concrete, repeatable mechanism).
**Location**: `ContestController.closeContest()`, `src/ContestController.sol:431-447`

**Description**: `closeContest` is gated only by `block.timestamp >= expiryTimestamp` — there is no restriction on the contract's prior state, so it can run from `SETTLED`. It transfers the **entire** live `paymentToken` balance to `oracle` and zeroes all pool accounting (`primaryPrizePool`, every entry's `secondaryLiquidityPerEntry`/`secondaryPrimarySubsidyPerEntry`), with no per-user reconciliation. If any primary winner or secondary holder has not yet claimed by the time `expiryTimestamp` passes — plausible whenever settlement itself happens close to or after expiry — the oracle can call `closeContest` and appropriate their already-earned, unclaimed payout.

**Proof of Concept**: Oracle calls `settleContest` at (or shortly before) `expiryTimestamp`. Before winners have had a chance to call `claimPrimaryPayout`/`claimSecondaryPayout`, the oracle (or anyone racing to front-run winners' claims, though `closeContest` itself is `onlyOracle`) calls `closeContest`, sweeping the full remaining balance — including every unclaimed payout — to `oracle`.

**Recommendation**: Restrict `closeContest` so it cannot run from `SETTLED`, or require a minimum claim window between settlement and eligibility for close, subtracting still-outstanding `primaryPrizePoolPayouts` and secondary liabilities from what's actually swept.

---

### 10. Duplicate or non-member `winningEntries` silently strand primary payout funds

**Severity**: Medium · **Confidence**: 78 · **Origin**: `[both]` — 1 Phase-1 agent, 4 of 12
Phase-2 agents (one of which, numerical-gap, identified the precise `=` vs `+=`
mechanism below).
**Location**: `ContestController.settleContest()`, `src/ContestController.sol:328`
(membership check), `:390` (primary-payout assignment), `:414` (spill accumulation)

**Description**: `winningEntries` is only checked for `length <= entries.length` (L328) — individual entries are never verified to be members of `entries[]`, and duplicates are not rejected. The primary-payout allocation loop **assigns** (`primaryPrizePoolPayouts[entryId] = payout`, L390), so a duplicate `entryId` has its second write silently overwrite the first — the entry ends up with only one BPS share's worth of payout even though `primaryPrizePool` was set to the full `netPrimary` covering both shares, stranding the difference (recoverable only via `closeContest`, to the oracle). The zero-supply spill loop, by contrast, **accumulates** (`primaryPrizePoolPayouts[eid] += extra`, L414) — so the same duplicate scenario is handled inconsistently between the two loops within the same function. A non-member `entryId` (never registered, or previously removed) allocates a payout that can never be claimed (`claimPrimaryPayout`/`pushPrimaryPayouts` both require a valid, matching `entryOwner`).

**Proof of Concept**: Oracle calls `settleContest(winningEntries=[5,5], payoutBps=[6000,4000])` with `netPrimary = 100_000`. The loop at L387-391 runs: `primaryPrizePoolPayouts[5] = 60_000`, then overwrites: `primaryPrizePoolPayouts[5] = 40_000`. `primaryPrizePool` is still set to the full `100_000`. Only `40_000` is ever claimable for entry 5; `60_000` is stranded until an oracle `closeContest`.

**Recommendation**: Validate each `winningEntries[i]` is an active member (`entryIndexPlusOne[entryId] != 0`) and reject duplicates before the payout loop; use `+=` consistently between the main allocation and the spill loop.

---

### 11. Bonding-curve "whale protection" is dead code for all realistic deposit sizes

**Severity**: Medium · **Confidence**: 88 · **Origin**: `[both]` — 3 of 7 Phase-1 agents, 3 of
12 Phase-2 agents, all independently converging on the same numeric threshold.
**Location**: `SecondaryPricing.calculatePrice()`, `src/SecondaryPricing.sol:31-36`

```solidity
uint256 sharesSquared = (shares / 1e9) * (shares / 1e9);
return BASE_PRICE + (sharesSquared * COEFFICIENT) / 1e18;
```

**Description**: Integer division floors `shares / 1e9` to 0 for any supply below one billion units, so the quadratic term is exactly zero across the entire realistic operating range of a deployed contest (reaching a doubling of `BASE_PRICE` requires roughly `shares ≈ 1e21`). The contract's own documentation ("large purchases cause dramatic price increases", "early bettors get better prices") does not hold: every buyer, regardless of size or timing, pays the same flat `BASE_PRICE`. This is not directly fund-draining on its own, but it is the mechanism that makes Finding 3 (settlement front-running) cheap, and it removes the intended economic friction against large late entries generally.

**Proof of Concept**: For a 6-decimal payment token, `calculateTokensFromCollateral(0, 5_000_000_000)` (5,000 tokens) returns essentially `4,999,999,999` shares — a flat ~1:1 conversion with zero curvature, confirmed by independent simulation in two separate agent passes.

**Recommendation**: Recalibrate `COEFFICIENT` and the `1e9`/`1e18` scaling constants so the quadratic term engages within the supply range realistic contests will actually reach, ideally parameterized by the payment token's decimals (see Finding 12's related decimals-assumption issue).

---

### 12. Fee-on-transfer / rebasing `paymentToken` breaks accounting assumptions

**Severity**: Medium · **Confidence**: 68 · **Origin**: `[both]` — 3 of 7 Phase-1 agents
(the ERC20-domain agent rated this High; taking Medium here given the precondition —
a fee-on-transfer/rebasing token must be deliberately chosen at deployment, an
unvalidated but non-default configuration choice), 2 of 12 Phase-2 agents.
**Location**: `ContestController.addPrimaryPosition()`, `src/ContestController.sol:153-162`;
`addSecondaryPosition()`, `src/ContestController.sol:209-216`

**Description**: Both inbound-deposit paths credit tracked accounting with the _nominal_ argument before/regardless of the actual token amount received — there is no `balanceOf` before/after delta measurement anywhere in the contract. `paymentToken` is chosen unconstrained at deployment (`ContestFactory.createContest`, no validation). A fee-on-transfer or rebasing token causes tracked liquidity/pool figures to permanently exceed the real contract balance. Several outbound paths defensively clamp to live `balanceOf` (`removeSecondaryPosition` L233-236, `claimSecondaryPayout` L276-279, `closeContest` L434) — but `claimPrimaryPayout` (L179-194) and `pushPrimaryPayouts` (L473-497) do not, and will simply revert once the real balance falls short, locking out later claimants.

**Proof of Concept**: Deploy with a 2%-fee-on-transfer token. Two contestants each `addPrimaryPosition` with `primaryDepositAmount = 100`; `primaryPrizePool` credits 200 but the contract actually receives 196. At settlement and claim time, the first claimant's transfer may succeed, but the shortfall accumulates until a later `claimPrimaryPayout` reverts against an insufficient balance.

**Recommendation**: Measure the actual received amount via a `balanceOf` delta around each inbound transfer and credit that instead of the nominal argument, or restrict `paymentToken` to a vetted allowlist of standard, non-fee, non-rebasing tokens at the factory level.

---

### 13. `claimSecondaryPayout` vs `pushSecondaryPayouts` residual-handling asymmetry

**Severity**: Low · **Confidence**: 80 · **Origin**: `[both]` — 2 of 7 Phase-1 agents, several
Phase-2 agents citing this as the comparison point that exposed Finding 1.
**Location**: `ContestController.claimSecondaryPayout()` L298-304 vs
`pushSecondaryPayouts()`, `src/ContestController.sol:499-536`

**Description**: The self-serve claim path carries the whole-balance sweep tail (Finding 1); the oracle-driven batch equivalent computes the identical pro-rata entitlement (L515-517) but has no such tail. Once Finding 1 is fixed, this residual finding is about making the two paths behave identically going forward — otherwise the final distribution for economically-identical holders still depends on which exit path they happen to use.

**Recommendation**: Factor the shared pro-rata computation into one internal function used by both entrypoints so they cannot diverge, and apply any residual-dust handling identically (or not at all) to both.

---

### 14. `pushPrimaryPayouts` reverts the whole batch on one stale `entryId`

**Severity**: Low · **Confidence**: 88 · **Origin**: `[phase1: dos]`
**Location**: `ContestController.pushPrimaryPayouts()`, `src/ContestController.sol:473-497`,
specifically the `require` at `:479`

**Description**: The batch loop's `require(owner != address(0), "Entry withdrawn or invalid")` (L479) runs _before_ the zero-payout skip (L482-484). One stale, withdrawn, or typo'd `entryId` in an oracle-submitted batch reverts the entire batch, including entries that would have paid out correctly. No funds are lost (the oracle can resubmit a cleaned batch), but it is an operational footgun matching the client's "operational headaches" framing directly.

**Recommendation**: Change the `require` to a soft `if (owner == address(0)) continue;`, consistent with the existing zero-payout skip immediately below it.

---

### 15. `pushSecondaryPayouts` reverts the whole batch on one blocklisted recipient

**Severity**: Low · **Confidence**: 82 · **Origin**: `[phase1: dos]`
**Location**: `ContestController.pushSecondaryPayouts()`, `src/ContestController.sol:531`

**Description**: The per-recipient `safeTransfer` inside the loop has no isolation — if `paymentToken` is a blocklist token and any one address in the oracle-supplied batch is blocklisted, the whole batch reverts. Impact is limited because unaffected holders retain `claimSecondaryPayout` as a self-serve fallback, and the oracle can simply omit the problem address from a resubmitted batch.

**Recommendation**: For robustness, wrap each transfer so a single failure skips that recipient rather than reverting the batch (e.g., a low-level call with a length-bounded revert-swallow, or `try/catch` on a transfer helper).

---

### 16. `secondaryDepositedPerEntry` goes stale on ERC1155 transfer

**Severity**: Low · **Confidence**: 88 · **Origin**: `[phase1: erc721]`
**Location**: `ContestController.removeSecondaryPosition()`, `src/ContestController.sol:238-242`;
no corresponding update on `safeTransferFrom`/`safeBatchTransferFrom`

**Description**: This mapping (documented in the source as "used by frontend UI," `src/ContestController.sol:73-74`, explicitly **not** used for pricing or payout math) is only updated on buy, sell, and claim — never on a plain ERC1155 transfer. After shares change hands, the recipient shows zero attributed principal and the sender retains stale principal for shares they no longer hold, producing meaningless forfeiture math on a subsequent `removeSecondaryPosition` call by either party and misleading UI figures. No fund-loss impact given the documented UI-only usage.

**Recommendation**: Either override the ERC1155 transfer hooks to move this value proportionally alongside `balanceOf`, or remove the field and derive UI principal off-chain from emitted events.

---

### 17. `_mint` fires before the payment pull in `addSecondaryPosition` (CEI violation)

**Severity**: Low · **Confidence**: 78 · **Origin**: `[phase1: erc721]`
**Location**: `ContestController.addSecondaryPosition()`, `src/ContestController.sol:209-216`

**Description**: Liquidity and supply are credited and ERC1155 shares minted (L209-214) — triggering `onERC1155Received` on a contract buyer — before the payment token is actually pulled (L216). This is a checks-effects-interactions violation. It is not currently exploitable: the function is `nonReentrant`, and every other value-moving entrypoint shares the same guard, so the callback cannot re-enter anything that would monetize the inconsistency; if the payment pull subsequently fails, the whole transaction (including the mint) reverts. This is recorded as a latent footgun dependent on that guard coverage never lapsing on a future code change, not as an active vulnerability.

**Recommendation**: Reorder to pull the payment token before minting, removing the reliance on `nonReentrant` for this path's correctness.

---

### 18. `addSecondaryPosition` has no expiry check (inconsistent with the primary path)

**Severity**: Low · **Confidence**: 82 · **Origin**: `[phase2: boundary]`
**Location**: `SecondaryContest.validateAddSecondaryPosition()`, `src/SecondaryContest.sol:33-42`,
compared with `PrimaryContest.validateAddPrimaryPosition()`, `src/PrimaryContest.sol:31-40`
(which does check `block.timestamp < expiryTimestamp` at line 39)

**Description**: The primary-add validator explicitly enforces the contest hasn't expired; the secondary-add validator gates only on `state` (`OPEN` or `ACTIVE`) and entry existence — it never checks `expiryTimestamp`. A contest that has passed its expiry but has not yet been moved to `CANCELLED` (nobody has called `cancelExpired` or the oracle hasn't called `cancelContest`) still accepts new secondary buy-ins, racing whichever cancellation eventually lands. Impact is bounded — such late buy-ins remain unwindable via `removeSecondaryPosition` once the contest reaches `CANCELLED` — so this is a consistency gap rather than a fund-loss path.

**Recommendation**: Add the same `block.timestamp < expiryTimestamp` check to `validateAddSecondaryPosition` for consistency with the primary path.

---

### 19. `ReferralGraph` ownership is one-step and transferable to `address(0)`

**Severity**: Low · **Confidence**: 80 · **Origin**: `[phase1: access-control]`
**Location**: `ReferralGraph` inherits solmate `Owned`, `lib/referralTree/src/core/ReferralGraph.sol:11,39`

**Description**: `transferOwnership` is single-step with no zero-address guard. A mistyped target or an intentional renounce-to-zero permanently and silently removes the ability to `authorizeOracle`/`unauthorizeOracle` for every group under that graph. Existing already-authorized oracles keep working indefinitely — including any address currently holding that role, whether or not it should still be trusted — with no way to revoke them afterward.

**Recommendation**: Use a two-step ownership pattern (e.g. `Owned2Step` / OpenZeppelin `Ownable2Step`) and reject `address(0)` as a transfer target.

---

### 20. Contest `oracle` is an immutable single point of failure with no pause

**Severity**: Low · **Confidence**: 75 · **Origin**: `[phase1: access-control]`
**Location**: `ContestController.oracle`, `src/ContestController.sol:32`; `onlyOracle`
modifier, `src/ContestController.sol:111-114`

**Description**: `oracle` is set once at construction with no rotation, transfer, or renounce mechanism, and drives every privileged lifecycle transition plus the fee/dust fallback recipient role. If the key is lost, the contest can never be activated, locked, or settled (participants can still recover principal via the `OPEN`/`CANCELLED` refund paths, but no contest can ever pay out its intended prize). If the key is compromised, the attacker controls all settlement outcomes and — combined with Finding 9 — can drain unclaimed funds post-settlement, with no on-chain path to rotate away from the compromised key.

**Recommendation**: Use a multisig for `oracle` in production deployments, and/or add a guarded rotation mechanism and an emergency pause on the deposit entrypoints.

---

### 21. Referral-tree cycles produce duplicate recipients in `getPayoutChain`

**Severity**: Info · **Confidence**: 65 · **Origin**: `[phase2: first-principles]`
**Location**: `ReferralGraph._register()`, `lib/referralTree/src/core/ReferralGraph.sol:208-222`;
`getPayoutChain()`, `lib/referralTree/src/core/ReferralGraph.sol:130-154`

**Description**: `_register` blocks direct self-referral (`referrer == user`) and re-registration of an already-registered user, but does not detect multi-node cycles (`register(A, referrer=B)` then, separately, `register(B, referrer=A)` — both individually pass the "referrer must already be in tree" check at registration time in the right order). `getPayoutChain`'s tree walk has no visited-set, only the `maxLevels` bound, so a cycle produces a chain listing the same addresses repeatedly. `RewardCalculator` normalizes the total to exactly `referralFee` regardless of recipient count, so no extra funds leave the contract — only the _distribution_ among intended ancestors is distorted in favor of the duplicated addresses.

**Recommendation**: Track ancestors visited during registration validation to reject cycle-forming registrations, or de-duplicate within `getPayoutChain`'s walk.

---

### 22. `uri()` always returns empty despite advertising ERC1155 metadata support

**Severity**: Info · **Confidence**: 90 · **Origin**: `[phase1: erc721]`
**Location**: `ContestController.uri()`, `src/ContestController.sol:538-540`

**Description**: Returns `""` for every token id, while inherited `supportsInterface` still advertises the `ERC1155MetadataURI` interface ID. No security impact — these are internal accounting tokens — but indexers/marketplaces relying on `uri()` will get nothing despite the advertised support.

**Recommendation**: Either implement real metadata or acknowledge the interface claim is inaccurate; no action required if intentionally out of scope.

---

## Items reviewed and cleared (no finding)

- **Settlement fee/net BPS sizing rounding**: `referralFee + netPrimary + netSecondary` always floors to ≤ `totalGross`, losing at most ~2 wei to the contract, never over-committing — solvency-safe in the unsafe direction only.
- **Zero-supply spill redistribution** (`src/ContestController.sol:403-420`): conserves the redistributed pool exactly, including the rounding remainder pushed to `winningEntries[0]`.
- **`netPosition` negative-cast risk**: every decrement of `netPosition[entryId]` is bounded by an actual burned ERC1155 balance; the value cannot go negative in practice despite the `int256`→`uint256` casts throughout.
- **Same-transaction round-trip / self-referral / OPEN-state sandwich attacks**: checked via simulation; the bonding curve and state-machine gating correctly prevent profitable same-tx extraction in these specific directions (distinct from Finding 3, which is a genuine cross-transaction/mempool-timing issue).
- **Bounded loops** (`ReferralGraph`'s skiplist/authorized-oracle-list swap-pop removal, `SecondaryPricing`'s 50-iteration binary search): not attacker-forceable into unbounded work; growth of these lists is privileged-actor-only.

---

_Audited under leftclaw job #391. This report was produced by an independent, automated
three-phase audit run specifically for this engagement — every finding above traces to
this run's own Phase 0 protocol map and Phase 1/2 agent output, cross-verified against
the source at the commit pinned above._
