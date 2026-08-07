# Secondary Market Economics: Sure-Winner Stress & Claim EV

## Worldview

Secondary is a **conviction market**, not a field-balancer:

| Layer | Behavior |
| ----- | -------- |
| **Pricing** | Local — each entry has its own quadratic bonding curve (`COEFFICIENT = 15`) |
| **Redemption** | Global — at settle, residual secondary TVL merges onto `secondaryWinner`; only that entry’s ERC1155 holders redeem |
| **Claim haircuts** | Loan repay (`primaryDepositSecondarySubsidyBps`) then referral (`referralNetworkBps`) on the residual pool |
| **Sizing** | `EV ≈ P(win) × (ownership of winning entry) × claimablePot − cost` |

The curve raises the **cost of late/large conviction**. It does **not** discover win probability. Capital can still concentrate when beliefs justify it; unprofitable regions are vs **claim EV**, not vs “balancing the book.”

Loser-entry capital funds winner claimants. Participants should size knowing that.

```text
claimablePot = sideBalance
  × (10000 − subsidyBps) / 10000   // loan repay (standard 7% → ×0.93)
  × (10000 − referralBps) / 10000  // referral haircut (standard 5% → ×0.95)
```

## Contest Configuration

| Parameter                          | Value | Description                                                                 |
| ---------------------------------- | ----- | --------------------------------------------------------------------------- |
| `PRIMARY_DEPOSIT`                  | $25   | Fixed amount each primary participant must deposit                            |
| `referralNetworkBps`               | 500   | Referral network fee: 5% of gross TVL at settlement (applied as netBps to residual secondary) |
| `primaryDepositSecondarySubsidyBps`| 700   | 7% carve to per-entry subsidy on deposit; same BPS of secondary TVL repaid to primary at settle |
| `minSecondaryPurchaseAmount`       | $1    | Minimum secondary buy: `10 ** paymentTokenDecimals` (rejects dust)            |
| `COEFFICIENT`                      | 15    | Quadratic bonding curve coefficient                                           |
| `BASE_PRICE`                       | 1e6   | Minimum price: 1.0 (scaled by PRICE_PRECISION)                                  |
| `PRICE_PRECISION`                  | 1e6   | Price precision: 1.0 = 1,000,000                                              |

Run: `forge test --match-path test/SecondaryPricingBreakeven.t.sol -vv` (max permissions; see [`agents.md`](../agents.md)).

## Test Setup (shared fixture)

- **5 primary entries** ($25 each → **$116.25** into `primaryPrizePool`, **$8.75** total into per-entry subsidy)
- **Each primary self-bets $20** secondary on their entry
- **Side balance:** **$108.75**; **expected claimable pot:** **~$96.08** (`$108.75 × 0.93 × 0.95`)
- Competitive suites: two bettors alternate **$10** purchases on Entry 1

---

## 1. Sure-winner stress (`P(win) = 1`)

**Conditional lab case** — values assume Entry 1 is `secondaryWinner` with certainty. Useful for curve + fee capacity; **not** typical player behavior.

### Break-even points

**Bettor 1** reaches break-even at **Purchase #9**; **Bettor 2** at **Purchase #10**.

| Purchase | Bettor | Tokens | Claimable pot after | Marginal value (P=1) | Net | Profitable? |
| -------- | ------ | ------ | ------------------- | -------------------- | --- | ----------- |
| #1 | B1 | ~9.91 | ~$104.92 | ~$34.80 | ~$24.80 | YES |
| #2 | B2 | ~9.82 | ~$113.75 | ~$28.15 | ~$18.15 | YES |
| #8 | B2 | ~8.89 | ~$166.76 | ~$10.38 | ~$0.38 | YES (barely) |
| #9 | B1 | ~8.70 | ~$175.60 | ~$8.80 | $0 | **NO — B1 break-even** |
| #10 | B2 | ~8.50 | ~$184.43 | ~$8.89 | $0 | **NO — B2 break-even** |

- Price at break-even: ~1.14–1.19× base
- After 50 purchases: side balance **$608.75**, claimable **~$537.83**, ownership ~47% / ~46%

**Insight:** Under sure-winner + fee-aware claimable pot, competition still hits break-even within one purchase of each other. The 5% referral haircut lowers absolute marginal values vs loan-repay-only tables; break-even purchase # stays ~9–10 under this fixture.

---

## 2. `P(win)`-weighted EV

Same duel path; for each purchase:

```text
EV = P(win) × Δownership × claimablePot − cost
```

| Belief | First unprofitable purchase # |
| ------ | ----------------------------- |
| `P = 1.00` | **9** |
| `P = 0.50` | **3** |
| `P = 0.20` | **1** (first buy already −EV) |

As belief falls, the profitable window collapses quickly. A thin longshot needs much stronger belief (or cheaper entry-local supply) to justify size — the curve alone does not price that belief.

---

## 3. Loser-float merge

Extra secondary TVL on entries 2–5, then `$100` concentrated on Entry 1; settle Entry 1 as `secondaryWinner`.

| Metric | Value (live run) |
| ------ | ---------------- |
| Entry 1 local TVL after buy | ~$121.75 |
| Global side balance after buy | ~$408.75 |
| Expected claimable residual | ~$361.13 |
| Bettor1 ownership of Entry 1 | ~82.3% |
| Expected / actual claim if Entry 1 wins | ~$297.24 |

**Claim ≫ local Entry 1 TVL** — redemption uses the **merged** residual pot (loser capital + winner capital after fees), not only what was bought on the winner.

---

## 4. Favorite vs thin (equal `$`)

Thicken Entry 1 with `$500` volume; leave Entry 2 at the `$20` self-bet; buy `$50` on each.

| Entry | Role | Tokens from `$50` | Ownership from that buy | Conditional claim if that entry wins |
| ----- | ---- | ----------------- | ----------------------- | ------------------------------------ |
| 1 | Favorite (thick) | ~18.1 | ~5.1% | ~$32.2 |
| 2 | Thin | ~48.4 | ~70.8% | ~$443.5 |
| | Token ratio thin/fav | **~2.68×** | | |

Thin entries mint more ownership per dollar because **local supply** is lower — not because the market implies a higher win probability. Sizing still requires an off-chain belief `P(win)`.

---

## Economic interpretation

### Marginal value (sure-winner)

```text
Marginal Cost = Marginal Value
$10 = Δownership × claimablePot
```

with `claimablePot` after loan repay **and** referral.

### Practical implications

1. **Sure-winner stress** — purchases #1–8 profitable for both; #9–10 break-even; #11+ destroy value under fee-aware pot.
2. **Uncertain outcomes** — use `P(win)`; at `P=0.5` the same path is unprofitable by purchase #3.
3. **Cross-entry capital** — buying the winner captures loser float; buying losers funds others.
4. **Curve role** — early/thin cheaper, whale/late friction; **not** win-probability discovery; **not** a mandate for a balanced book.

### Secondary payment flow

On `addSecondaryPosition(entryId, amount)`:

1. Caller transfers `amount` into the contest.
2. Full `amount` credits `secondaryLiquidityPerEntry[entryId]` (OPEN/CANCELLED sell-back collateral).
3. Curve-priced ERC1155 shares mint to `msg.sender`.
4. Referral fees apply at settlement (pool haircut), not per trade.

On `addPrimaryPosition`, **7%** of `PRIMARY_DEPOSIT` credits `secondaryPrimarySubsidyPerEntry[entryId]`. At `settleContest`, **7% of total secondary TVL** repays primary; residual secondary (after referral) merges to `secondaryWinner`.

## Conclusion

With `COEFFICIENT = 15`, subsidy **700**, referral **500**:

- Local curve + fees cap sure-winner pile-on around purchases **#9–10** in the standard duel fixture.
- Real conviction sizing is `P(win)`-weighted; lower belief → earlier break-even.
- Claims are funded by the **merged** residual pot — loser float matters.
- Equal dollars buy more ownership on thin entries; that is supply, not implied odds.

Curve mechanics smell-tests: [`SecondaryPricingSimulation.md`](SecondaryPricingSimulation.md). Parameter gates: [`SecondaryPricingTuning.md`](SecondaryPricingTuning.md).
