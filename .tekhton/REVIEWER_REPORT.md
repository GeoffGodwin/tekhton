# Reviewer Report — m27.1 Env Audit Script + Initial Inventory (Cycle 1)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `tests/test_audit_bash_env.sh:9` — `set -euo pipefail` combined with bare `return 1` in `_assert_exit` / `_assert_empty_stdout` / `_assert_contains` means the script aborts on the first failing assertion. The `FAILED_CASES` array and the end-of-test summary ("FAIL: N cases failed") are unreachable when any case fails. The test still exits non-zero (CI catches it), but subsequent fixtures do not run and the failure list is never printed. Consider wrapping each assertion call site with `|| true` and relying solely on `FAILED_CASES` for reporting, or remove `set -e` and gate the final exit on `${#FAILED_CASES[@]}`.
- `tests/test_audit_bash_env.sh:23` — `_run_audit` captures stderr via `2>&1`, so any stderr output from the audit script ends up in `AUDIT_OUTPUT`. In practice harmless because `tekhton` is committed at `${REPO_ROOT}/tekhton` and `_resolve_tekhton_bin` finds it before inspecting PATH. But if the binary were absent, the `# WARNING:` fallback message would contaminate `AUDIT_OUTPUT` and cause false failures in every `_assert_empty_stdout` call. Consider discarding stderr (`2>/dev/null`) since no current test case asserts on stderr content.
- `scripts/audit-bash-env.sh:136` — `find "${t}" -type f -name '*.sh'` has no `--` option terminator before the variable-derived path. Shellcheck passes; paths in `lib/`/`stages/` never start with `-`, so this is harmless in practice. Noted against the reviewer checklist.
- `scripts/audit-bash-env.sh` (general) — intra-line single-quoted strings are not excluded from scanning. `echo '${MILESTONE_MODE}'` would be flagged as a finding even though bash does not expand single-quoted content. The ACs only require heredoc exclusion, so this is within scope, but m27.2 triage should be aware that any flagged line where the reference sits inside `'…'` inline quotes is a known false positive.

## Coverage Gaps
- No test exercises the binary-absent fallback path (hardcoded allowlist + `# WARNING:` stderr line). A test case that stubs out `TEKHTON_BIN` and restricts PATH would confirm the fallback exits correctly and produces no stdout findings on negative fixtures.
- No test documents the inline single-quoted string false-positive scenario (`echo '${MILESTONE_MODE}'`), which would serve as a regression guard if the scanner is later extended to handle that case.

## Drift Observations
- None
