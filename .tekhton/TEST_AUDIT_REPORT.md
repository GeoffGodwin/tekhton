## Test Audit Report

### Audit Summary
Tests audited: 2 files, 8 test cases (7 named scenarios in test_audit_sampler.sh; inline assertions in test_tekhton_dir_root_cleanliness.sh)
Verdict: PASS

### Findings

#### INTEGRITY: Broken negative assertion in prune test always passes
- File: tests/test_audit_sampler.sh:207
- Issue: `! grep -q '"file":"tests/f1.sh"$' "$_TEST_AUDIT_HISTORY_FILE"` — the `$` end-of-line anchor prevents this pattern from ever matching a JSONL line. Lines written by `_record_audit_history` end with `}` (e.g. `{"ts":"...","file":"tests/f1.sh"}`), not with `"file":"tests/f1.sh"`. `grep` therefore always returns non-zero (no match), `!` inverts to success, and the assertion is a no-op. It passes whether or not f1.sh was actually pruned. The test is accidentally correct — the line-count check at line 203 (`LINES -eq 10`) and the f25 presence check at line 206 do catch pruning breakage — but the "absent" assertion contributes nothing and creates false confidence.
- Severity: MEDIUM
- Action: Replace with a pattern that actually matches JSONL structure. Either remove the `$` anchor (`grep -q '"file":"tests/f1.sh"'`) or, to avoid matching f10.sh–f19.sh, include the closing brace (`grep -qF '"file":"tests/f1.sh"}'`).

#### COVERAGE: Disabled-toggle test exercises a simulated gate, not the real run_test_audit gate
- File: tests/test_audit_sampler.sh:151-169
- Issue: Test 5 simulates the `TEST_AUDIT_ROLLING_ENABLED=false` gate inline rather than calling `run_test_audit`. The real gate lives at lib/test_audit.sh:351-354. If that gate were removed or its condition changed, this test would still pass because it is asserting its own copy of the guard logic, not the production path.
- Severity: LOW
- Action: Acceptable trade-off — exercising `run_test_audit` would require the full pipeline harness (agent stubs, prompt rendering). Add an inline comment explicitly stating that the test verifies the sampler function's passivity when skipped by the caller and points to the canonical gate at lib/test_audit.sh:351-354.

#### SCOPE: Shell symbol detector false positives — all flagged "orphans" are builtins
- File: tests/test_tekhton_dir_root_cleanliness.sh (all flagged references)
- Issue: The pre-verified orphan list flags `:`, `cd`, `compgen`, `continue`, `cut`, `dirname`, `echo`, `grep`, `pwd`, `read`, `set`, and `source` as stale references not found in any source definition. All are POSIX shell builtins or standard utilities, not user-defined functions. The symbol detector (lib/test_audit_symbols.sh) cannot distinguish them from implementation symbols. There are no actual orphaned references in this file.
- Severity: LOW
- Action: No action needed on the test file. The symbol detector should maintain an exclusion list of well-known shell builtins and PATH utilities to suppress these false positives.

### Positive Findings (no issues)

**Assertion Honesty — test_audit_sampler.sh (Tests 1–4, 6):** Every assertion derives from actual implementation output. File counts come from `_sample_unaudited_test_files` with real git-staged files. JSONL field checks (`"file":`, `"ts":"`) match the exact format written by `_record_audit_history` (lib/test_audit_sampler.sh:54). The oldest-first ordering test (Test 3) uses ISO-8601 timestamps that sort lexicographically, consistent with the implementation's `LC_ALL=C sort` at lib/test_audit_sampler.sh:127.

**Test Isolation:** `test_audit_sampler.sh` initialises a fresh `mktemp -d` temp directory, assigns it as both `PROJECT_DIR` and the git repo root, stubs all pipeline logging functions, and tears everything down via `trap 'rm -rf ...' EXIT`. Per-test state is reset by `_reset_sampler_state`. No mutable project files (pipeline logs, `.tekhton/` reports, `.claude/logs/*`) are read.

**test_tekhton_dir_root_cleanliness.sh** sources `config_defaults.sh` in a subshell with minimal stubs. The subshell's environment is fully controlled; no mutable project state is read.

**Implementation Exercise:** Both test files source and call real implementation functions directly. `test_audit_sampler.sh` exercises `_sample_unaudited_test_files`, `_record_audit_history`, `_prune_audit_history`, and `_ensure_test_audit_history_file` in lib/test_audit_sampler.sh with real git repos and real file I/O. `test_tekhton_dir_root_cleanliness.sh` sources the actual `lib/config_defaults.sh`. No mocking of the functions under test.

**Scope Alignment:** The `TEST_SYMBOL_MAP_FILE` exclusion added to `test_tekhton_dir_root_cleanliness.sh` is justified. The variable does not appear in `config_defaults.sh` (confirmed by inspection); it is set at runtime by `lib/test_audit_symbols.sh` and can leak into the pipeline environment. Excluding it prevents false failures without reducing coverage of actual config defaults.

**Test Weakening:** `test_tekhton_dir_root_cleanliness.sh` was modified only by adding one entry to the EXCLUDED map (additive, not reductive). No existing assertions were removed or broadened.

**Test Naming:** All 7 scenario names in `test_audit_sampler.sh` encode both the scenario and expected outcome (e.g. `test_sampler_returns_k_files`, `test_sampler_skips_recently_audited`, `test_sampler_oldest_first`, `test_prune_audit_history`).
