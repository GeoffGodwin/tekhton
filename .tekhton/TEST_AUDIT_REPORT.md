## Test Audit Report

### Audit Summary
Tests audited: 1 file, 25 test assertions
Verdict: CONCERNS

---

### Findings

#### ISOLATION: VERSION file assertion reads live mutable repo state
- File: tests/test_migrate_032_completeness.sh:120-130
- Issue: Section 4 reads `${TEKHTON_HOME}/VERSION` directly and asserts `[[ "$ver" == "3.137.0" ]]`. This is a hard-coded snapshot assertion against a committed file that is mutated by every milestone. The test will fail as soon as M138 bumps VERSION to `3.138.0` — at that point it produces a false negative against a fully-correct implementation. There is no fixture copy of VERSION in `$TEST_TMPDIR`; pass/fail depends entirely on current repo state.
- Severity: HIGH
- Action: Remove the VERSION assertion from this file. Milestone acceptance is already tracked via MANIFEST.cfg status. If a version smoke-check is needed, assert that the version is lexicographically greater than the prior milestone (`[[ "$ver" > "3.136.0" ]]`) rather than pinning an exact value.

#### ISOLATION: MANIFEST.cfg checks read a live project file
- File: tests/test_migrate_032_completeness.sh:136-159
- Issue: Sections MAN1–MAN3 read `${TEKHTON_HOME}/.claude/milestones/MANIFEST.cfg` directly without copying it to `$TEST_TMPDIR`. The specific assertions on M137's row (`depends_on=m135,m136`, `group=resilience`) are stable properties that will not change, but the test is formally coupled to live repo state. A structural reformat of MANIFEST.cfg or a format-version bump would break these assertions for reasons unrelated to the migration script under test.
- Severity: MEDIUM
- Action: Copy MANIFEST.cfg to `$TEST_TMPDIR` at the start of Section 5 and read from the copy; or annotate the test block as a one-time acceptance check explicitly excluded from the ongoing regression suite.

#### SCOPE: VERSION and MANIFEST checks verify coder deliverables, not migration script behavior
- File: tests/test_migrate_032_completeness.sh:120-159
- Issue: `031_to_032.sh` does not touch VERSION or MANIFEST.cfg. Sections 4 and 5 verify acceptance criteria for M137 as a whole (coder bumped VERSION, MANIFEST row was authored correctly). These checks will produce misleading failures in CI after M138 that look like migration regressions when the migration script itself is unchanged.
- Severity: LOW
- Action: Move VERSION and MANIFEST.cfg checks to a dedicated one-shot acceptance script (e.g., `tests/test_m137_acceptance.sh`) documented as milestone-locked and excluded from the ongoing regression glob, or remove Section 4 entirely (Section 5 assertions are stable and lower-risk).

---

### Clean Findings (no issues)

**Assertion Honesty — PASS.** All assertions in Sections 1–3 and 6 are derived from actual implementation content. The 12 commented-key patterns in `_assert_var_present` exactly match strings emitted by `_032_append_arc_config_section` (verified against `migrations/031_to_032.sh:68–83`). The plan-deviation guards (V2–V5) correctly check that `100` and `10` appear while `1.0` and `5` do not — matching the implementation at lines 70 and 83. No tautological or fabricated assertions found.

**Implementation Exercise — PASS.** The test sources `migrations/031_to_032.sh` directly and invokes `migration_apply`, `migration_check`, and `migration_description` with real fixtures in `$TEST_TMPDIR`. Nothing under test is mocked.

**Edge Case Coverage — PASS.** Plan-deviation negative guards (V4, V5) and the chain migration (Section 6) provide meaningful non-happy-path coverage beyond `test_migrate_032.sh`'s T1–T12.

**Test Weakening — N/A.** No existing tests were modified; this is a new additive file.

**Test Naming — PASS.** Labels (V1–V5, D1, VER, MAN1–3, CHAIN1–3) encode both scenario and expected outcome. All names are descriptive.

**Test Isolation (Sections 1–3, 6) — PASS.** Project fixtures are created in `$TEST_TMPDIR` with a `trap 'rm -rf "$TEST_TMPDIR"' EXIT` guard. Logging functions are stubbed before sourcing. The chain test applies the 3.1 migration in a subshell to prevent function-name collisions with the already-sourced 3.2 functions. `migrations/003_to_031.sh` (sourced at line 187) is confirmed present.
