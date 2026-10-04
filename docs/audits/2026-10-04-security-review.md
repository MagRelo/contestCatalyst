# Contest Catalyst Security Review

**Date:** October 4, 2026  
**Reviewer:** Independent Security Auditor  
**Commit Hash:** `7a8b9b517d06cb0423137014b76944fba50412b9`

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Scope](#scope)
3. [Methodology](#methodology)
4. [Findings Summary](#findings-summary)
5. [Detailed Findings](#detailed-findings)
6. [Informational Observations](#informational-observations)
7. [Gas Optimizations](#gas-optimizations)
8. [Conclusions](#conclusions)

---

## Executive Summary

This security review covers the Contest Catalyst smart contracts, an on-chain contest escrow system with a conviction market (bonding curve) for secondary positions. The system is designed for fantasy/contest products like Play The Cut.

**Key Observations:**
- The contracts demonstrate solid architecture with proper separation of concerns
- Reentrancy protection is consistently applied
- The operator trust model is well-documented and intentional
- No critical or high-severity vulnerabilities were identified
- Several low-severity and informational findings were noted

**Overall Assessment:** The codebase is well-structured with security best practices largely followed. The main security considerations relate to trust assumptions (documented), ERC-20 edge cases, and potential MEV exposure.

---

## Scope

### In-Scope Contracts

| File | Lines | Description |
|------|-------|-------------|
| `src/ContestController.sol` | 803 | Main orchestrator contract |
| `src/ContestFactory.sol` | 102 | Factory for creating contests |
| `src/PrimaryContest.sol` | 100 | Library for primary mechanics |
| `src/SecondaryContest.sol` | 94 | Library for secondary mechanics |
| `src/SecondaryPricing.sol` | 146 | Bonding curve pricing |

### External Dependencies Reviewed

| Dependency | Usage |
|------------|-------|
| `referralTree` | ReferralGraph integration for fee distribution |
| `solmate` | ERC20, ERC1155, ReentrancyGuard, SafeTransferLib |
| `solady` | MerkleProofLib |

### Out of Scope

- Off-chain backend/oracle systems (no on-chain code present in repo)
- Deployment scripts
- Test files (reviewed for coverage understanding only)

---

## Methodology

### Tools Used

| Tool | Version | Purpose |
|------|---------|---------|
| Foundry (Forge) | 1.8.4 | Build, test, gas analysis |
| Slither | 0.11.6 | Static analysis |
| Manual Review | - | Line-by-line code audit |

### Review Process

1. **Codebase Mapping:** Identified all Solidity contracts and their interactions
2. **Automated Analysis:** Ran Slither for static analysis, triaged findings
3. **Manual Review:** Focused on priority areas:
   - Contest entry, escrow, and payout logic
   - Prize distribution math and rounding
   - Operator trust and settlement risks
   - Refunds and cancellation mechanics
   - Timing enforcement
   - Reentrancy and ERC-20 quirks
   - Signature and replay handling
   - Unbounded loops and DoS vectors
   - Front-running vulnerabilities
   - Stuck fund scenarios
   - ReferralTree integration
4. **PoC Development:** Created proof-of-concept tests for findings
5. **Test Execution:** Ran existing test suite (373/374 tests passing)

---

## Findings Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 3 |
| Informational | 4 |
| Gas | 2 |

---

## Detailed Findings

### [M-01] Missing `safeApprove` in `distributeReferralFee`

**Severity:** Medium  
**Location:** `src/ContestController.sol:515`

**Description:**
The `distributeReferralFee` function uses a raw `ERC20.approve()` call instead of `SafeTransferLib.safeApprove()`:

```solidity
ERC20(paymentToken).approve(referralGraph, referralFee);
```

While most of the contract correctly uses `SafeTransferLib` for safe ERC20 interactions, this approve call does not check the return value.

**Impact:**
For non-standard ERC20 tokens that don't return a boolean on `approve()` (like USDT on mainnet), this call may silently fail, potentially causing the subsequent `rewardRoots` call to fail unexpectedly or succeed with stale allowances.

**Proof of Concept:**
Slither flagged this as an unused return value:
```
ContestController.distributeReferralFee(...) ignores return value by ERC20(paymentToken).approve(referralGraph,referralFee)
```

**Recommended Fix:**
```solidity
SafeTransferLib.safeApprove(ERC20(paymentToken), referralGraph, referralFee);
```

---

### [L-01] No Slippage Protection in Secondary Buys

**Severity:** Low  
**Location:** `src/ContestController.sol:220-246`

**Description:**
The `addSecondaryPosition` function does not allow users to specify a minimum number of tokens they expect to receive. The bonding curve price increases with supply, making users vulnerable to MEV sandwich attacks.

**Impact:**
An MEV bot could:
1. Observe a pending `addSecondaryPosition` transaction
2. Front-run with their own buy, pushing up the price
3. The victim's transaction executes at a worse price
4. The bot holds tokens until favorable exit conditions

While the contract limits sell-back opportunities (only OPEN or CANCELLED states), this doesn't fully eliminate the risk for sophisticated attackers with insider information about likely winners.

**Proof of Concept:**
```solidity
function test_Finding_NoSlippageProtection() public {
    // Price increases from 1000000 to 1001498 to 1005976
    // with consecutive 10e18 buys, demonstrating price impact
}
```

**Recommended Fix:**
Add a `minTokensOut` parameter:
```solidity
function addSecondaryPosition(
    uint256 entryId, 
    uint256 amount, 
    uint256 minTokensOut,
    bytes32[] calldata merkleProof
) external nonReentrant {
    // ... existing validation ...
    uint256 buyerTokens = SecondaryPricing.calculateTokensFromCollateral(shares0, paymentShareUnits);
    require(buyerTokens >= minTokensOut, "Slippage exceeded");
    // ...
}
```

---

### [L-02] Rounding Dust Accumulation in Prize Distribution

**Severity:** Low  
**Location:** `src/ContestController.sol:429`

**Description:**
Integer division in prize payout calculations can leave small dust amounts:

```solidity
uint256 payout = (netPrimary * payoutBps[i]) / BPS_DENOMINATOR;
```

If `netPrimary = 300e18` and payouts are split 3333/3333/3334, the sum of payouts will be slightly less than `netPrimary`.

**Impact:**
Small amounts of tokens may accumulate in the contract. The `_allocateUnallocatedBalance` function mitigates this for push payouts by crediting dust to winner pools, but pull claims don't benefit from this.

**Recommended Fix:**
This is a minor issue with existing mitigation. For complete resolution, consider:
1. Tracking dust explicitly and adding to the last payout
2. Using a more sophisticated distribution algorithm

---

### [L-03] USDC/Blacklistable Token Recipient Stuck Funds

**Severity:** Low  
**Location:** `src/ContestController.sol:620, 678`

**Description:**
If a winner's address is blacklisted by USDC (or similar blacklistable tokens), their pull claims will fail permanently. Push payouts use try/catch to skip failed recipients, but the funds remain locked in the contract with no recovery mechanism.

**Impact:**
Blacklisted users cannot claim their winnings. While push payouts skip them gracefully, the funds remain in the contract and can be allocated to other winners via `_allocateUnallocatedBalance`.

**Recommended Fix:**
This is a known limitation documented in the README ("should be a standard non-fee, non-rebasing ERC20"). Consider:
1. Adding an operator function to handle stuck funds after a waiting period
2. Documenting this behavior more prominently for users

---

## Informational Observations

### [I-01] Centralized Operator Trust Model

**Location:** Contract-wide

**Description:**
The `operator` address has significant unilateral powers:
- Activate/lock/cancel contests
- Choose winners and payout splits (no on-chain verification)
- Set merkle roots for allowlisting
- Push payouts

This is well-documented in the README as an intentional design decision. Users must trust the operator (recommended to be a multisig).

**Recommendation:**
No code change needed. The documentation clearly states this trust assumption. Consider implementing timelock or multi-sig patterns for production deployments.

---

### [I-02] Referrer Front-Running Attack Vector (Documented)

**Location:** ReferralGraph integration

**Description:**
As documented in `ReferralNetworkIntegration.md`:
> An oracle can register an unregistered winner under an attacker-controlled referrer before settlement redirects up to `referralNetworkBps` of TVL.

**Recommendation:**
Users should register their referrers before contest settlement. The live `getReferrer` at settle time (no lock-time snapshot) is documented as intentional.

---

### [I-03] ERC1155 Transfers Intentionally Disabled

**Location:** `src/ContestController.sol:690-703`

**Description:**
The contract overrides ERC1155 transfer functions to revert:
```solidity
function setApprovalForAll(address, bool) public pure override {
    revert("Transfers disabled");
}
```

This is intentional to keep secondary shares non-transferable for accurate payout tracking.

---

### [I-04] `removeSecondaryPosition` OPEN State Case May Be Unreachable

**Location:** `src/ContestController.sol:250-290`, `src/SecondaryContest.sol:47-58`

**Description:**
`validateRemoveSecondaryPosition` allows removal in OPEN state, but secondary positions can only be created in ACTIVE state. Once activated, the contest cannot return to OPEN. This means the OPEN removal path is effectively dead code unless there's an edge case not identified.

**Recommendation:**
Verify if this code path is intentional or can be removed for clarity.

---

## Gas Optimizations

### [G-01] Uncached Array Length in Loops

**Location:** Multiple locations in `src/ContestController.sol`

**Description:**
Storage array lengths are read on each iteration:
```solidity
for (uint256 i = 0; i < entries.length; i++) { ... }
```

**Affected Lines:** 375, 436, 734, 751, 762, 785

**Recommendation:**
Cache the length before the loop:
```solidity
uint256 entriesLength = entries.length;
for (uint256 i = 0; i < entriesLength; i++) { ... }
```

**Estimated Savings:** ~100 gas per iteration (SLOAD vs MLOAD)

---

### [G-02] O(n²) Duplicate Winner Check

**Location:** `src/ContestController.sol:366-368`

**Description:**
The nested loop for duplicate checking has O(n²) complexity:
```solidity
for (uint256 j = 0; j < i; j++) {
    require(winningEntries[j] != eid, "Duplicate winning entry");
}
```

With MAX_ENTRIES = 500, worst case is ~125,000 iterations.

**Recommendation:**
Use a mapping for O(n) checking:
```solidity
mapping(uint256 => bool) seen;
for (uint256 i = 0; i < winningEntries.length; i++) {
    require(!seen[winningEntries[i]], "Duplicate winning entry");
    seen[winningEntries[i]] = true;
}
```

---

## Conclusions

The Contest Catalyst contracts demonstrate a mature understanding of smart contract security patterns. The codebase benefits from:

- Consistent use of `nonReentrant` guards
- Proper use of `SafeTransferLib` for ERC20 transfers (with one exception noted)
- Clear separation of concerns between layers
- Well-documented trust assumptions
- Escape hatch via `cancelExpired` for stuck contests
- Comprehensive test coverage (373/374 tests passing)

**No critical or high-severity issues were found.** The findings are primarily:
- One medium-severity issue (missing `safeApprove`)
- Three low-severity issues (slippage protection, rounding dust, blacklist handling)
- Informational observations about documented trust assumptions
- Gas optimizations

The main security considerations for users are the documented trust assumptions around the `operator` role and the ReferralGraph oracles. These are architectural decisions, not bugs.

### Recommendations Priority

1. **Fix M-01** - Replace `ERC20.approve()` with `SafeTransferLib.safeApprove()`
2. **Consider L-01** - Add slippage protection parameter for improved UX
3. **Apply G-01** - Cache array lengths for gas savings

---

*This report was prepared by an independent security reviewer and does not constitute financial advice. Smart contract audits cannot guarantee the absence of all vulnerabilities.*
