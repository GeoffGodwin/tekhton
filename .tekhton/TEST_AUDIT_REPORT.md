## Test Audit Report

### Audit Summary
Tests audited: 2 files (tests/test_audit_bash_env_coverage.sh, tests/testdata/audit_bash_env/07-single-quoted.sh), 3 test cases
Verdict: PASS

### Findings

#### ISOLATION: PATH stripping may not cover all tekhton installation locations
- File: tests/test_audit_bash_env_coverage.sh:31-32
- Issue: The binary-absent simulation uses three defenses: (1) `TEKHTON_BIN=/nonexistent` neutralizes the env-var path, (2) copying the script to a tmpdir neutralizes the `${REPO_ROOT}/tekhton` and `${REPO_ROOT}/bin/tekhton` repo-relative paths, and (3) `_NO_BIN_PATH` strips `${TEKHTON_HOME}/bin` from PATH to defeat `command -v tekhton`. Defense (3) only filters one directory. If `tekhton` is installed anywhere else on PATH — `~/go/bin`, `/usr/local/bin`, or a developer's custom `bin/` — `command -v tekhton` inside the audit subprocess will still succeed, the fallback code path will not execute, no `# WARNING:` will be emitted, and both `fallback-guarded-warning` and `fallback-unguarded-warning` assertions will fail unexpectedly. CI environments that install the binary via `go install` are the likeliest failure surface.
- Severity: MEDIUM
- Action: Replace the selective grep-and-strip approach with a minimal PATH override. One-line fix: `_NO_BIN_PATH="/usr/bin:/bin"`. This makes the subprocess's PATH contain only POSIX core directories, which is strictly more reliable than trying to enumerate and strip known installation directories.

#### NAMING: False-positive assertion labels are ambiguous on failure
- File: tests/test_audit_bash_env_coverage.sh:136-137
- Issue: Case 3 uses assertion labels `"single-quoted-exit"` and `"single-quoted-finding"`. The test intentionally asserts that a known false positive IS flagged by the scanner. If someone later extends the scanner to correctly exclude intra-line single-quoted content, these assertions will fail — but the failure message `FAIL: single-quoted-exit — expected exit 1, got 0` reads as a detection regression, not as evidence of a fix. A maintainer unfamiliar with the intent would debug in the wrong direction before noticing the test comment.
- Severity: MEDIUM
- Action: Rename the labels to encode the known-false-positive intent, e.g., `"known-fp-single-quoted-exit"` and `"known-fp-single-quoted-finding"`. The resulting failure message `FAIL: known-fp-single-quoted-exit — expected exit 1, got 0` immediately signals that a documented limitation was fixed and the test requires a deliberate update.

#### COVERAGE: Binary-absent fallback exercised with only 2 of 6 detection cases
- File: tests/test_audit_bash_env_coverage.sh:99-118
- Issue: The fallback path (hardcoded minimal allowlist + `# WARNING:` on stderr) is exercised only against the guarded (01) and unguarded (02) fixtures. Comment-suppression (03), `${VAR+x}` conditional guard (04), out-of-allowlist (05), and single-quoted heredoc (06) behavior under the fallback allowlist are untested. The awk skip paths for comments and heredocs are allowlist-independent, but an independent reader cannot confirm this from the tests alone.
- Severity: LOW
- Action: Not a blocking gap — the six primary detection behaviors are fully exercised with the binary-derived allowlist in `test_audit_bash_env.sh`, and the awk skip paths are structurally independent of allowlist content. Acceptable as-is. If depth is desired, adding one extra fallback case (e.g., 06-heredoc) would close the category.

### Notes

No weakening detected. All changes are net-new test functions and fixture files. No existing assertions were removed or relaxed.

No scope alignment issues. All fixture references (`01-guarded.sh`, `02-unguarded.sh`, `07-single-quoted.sh`) correspond to files present in the current working tree. No stale imports or deleted-module references.

Assertion honesty is sound for all three cases. Cases 1 and 2 derive their expected values from the implementation's `_pipeline_conf_keys()` fallback path and `_scan_files()` awk matcher — both reachable code paths. Case 3's "known false positive" pattern explicitly tests a documented limitation. The test is honest: it asserts current behavior (the scanner flags single-quoted inline content), documents why, and explicitly invites future breakage when the limitation is fixed. This is a valid regression-guard pattern, not an integrity violation.

Test isolation is clean. A temp directory is created per run via `mktemp -d` with an `EXIT` trap cleanup. All fixture files read are checked-in static data, not mutable pipeline artifacts. No `.tekhton/*.md`, `.claude/logs/*`, or run-state files are read.
