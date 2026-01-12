# Agent Instructions

## Running Tests

**IMPORTANT: All tests must be run with maximum permissions.**

When running Forge tests, especially those that interact with the blockchain or require system access, you must use the `--all` permission flag or equivalent maximum permissions setting.

### Example

When running tests in this codebase, always use maximum permissions:

```bash
forge test --match-test test_BreakEvenAnalysis -vv
```

**Note:** In automated environments (like Cursor AI or CI/CD), ensure the test runner has `required_permissions: ['all']` or equivalent maximum permissions setting enabled.

If you encounter keychain or permission errors, ensure you're running with maximum permissions enabled.

### Why Maximum Permissions Are Needed

Some tests may require:

- Network access for external dependencies
- System keychain access for cryptographic operations
- Full filesystem access for test artifacts
- Git write access for test fixtures

Always run tests with maximum permissions to avoid these common issues.

## Standard Contract Settings

**IMPORTANT: All tests and documentation must use the initial contract settings defined in `test/SecondaryPricingBreakeven.t.sol` and `SecondaryPricingBreakeven.md`.**

To maintain consistency in assumptions and analysis across all tests and documentation, use the following standard contract settings:

### Contest Configuration

The standard initial contract settings are defined in:

1. **`test/SecondaryPricingBreakeven.t.sol`** - See the `setUp()` function (lines 55-92) and constants at the top of the file:

   - `PRIMARY_DEPOSIT = 25e18` ($25)
   - `oracleFeeBps = 500` (5%)
   - `positionBonusShareBps = 500` (5%)
   - `targetPrimaryShareBps = 3000` (30%)
   - `maxCrossSubsidyBps = 1500` (15%)
   - `PURCHASE_INCREMENT = 10e18` ($10)

2. **`SecondaryPricingBreakeven.md`** - See the "Contest Configuration" section (lines 3-17):
   - `PRIMARY_DEPOSIT`: $25
   - `oracleFeeBps`: 500 (5%)
   - `positionBonusShareBps`: 500 (5%)
   - `targetPrimaryShareBps`: 3000 (30%)
   - `maxCrossSubsidyBps`: 1500 (15%)
   - `COEFFICIENT`: 1
   - `BASE_PRICE`: 1e6
   - `PRICE_PRECISION`: 1e6

### Usage Guidelines

- **All new tests** should use these exact settings in their `setUp()` functions
- **All documentation** should reference these settings when describing contest behavior
- **All analysis** should assume these settings unless explicitly stated otherwise
- If different settings are needed for a specific test case, document why they differ from the standard

This consistency ensures that:

- Test results are comparable across different test files
- Documentation accurately reflects the assumptions used in tests
- Analysis and simulations use the same baseline assumptions
