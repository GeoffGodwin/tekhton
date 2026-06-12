## Verdict
APPROVED_WITH_NOTES

All three simple blockers from cycle 1 are resolved. No regressions introduced by the rework.

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `scripts/audit-raw-claude.sh:91` — The comment-filtering `grep -v '^[[:space:]]*#'` is applied against `lineno:matched` formatted output (the first grep emits `lineno:content`), so the pattern never actually matches real comment lines. A comment like `# cmd | claude foo` would slip through if the pattern fires on the `|` in the comment. Fail-safe direction (false positives cause audit failures, not missed violations), but the filter is a no-op as written. Fix: change to `grep -vE '^[0-9]+:[[:space:]]*#'` to match the actual output format.
- `internal/runner/supervise_bridge.go:57` — `os.ReadFile(req.PromptFile)` path-containment issue carried from cycle 1 (LOW/A01 security note). Still unaddressed but not introduced by this rework.
- `cmd/tekhton/supervise.go` — `--no-retry` deprecation warning still absent (carried from cycle 1).

## Coverage Gaps
- `tests/test_mcp_resolve_provider_guard.sh` and `tests/test_common_usage_threshold_guard.sh` were referenced in cycle 1 as self-skipping until the guards landed. Confirm these tests now unskip and pass with the guards in place; if they remain skipped, the CI gate is still open.

## Drift Observations
- None

## Blocker Verification (re-review evidence)

**Blocker 1 — `lib/mcp_resolve.sh:158`** FIXED.
Lines 158–163 add the provider-spec guard before the `claude --help` probe:
resolves `${PROVIDER:-codex,claude}`, logs the required skip message when `claude`
is absent, sets `_CLI_MCP_CONFIG_SUPPORTED=0`, and returns 1. Matches the blocker
description exactly.

**Blocker 2 — `lib/common.sh:175`** FIXED.
Lines 173–176 add the provider-spec guard: resolves `${PROVIDER:-codex,claude}`,
returns 0 silently when `claude` is not in the spec. No `claude usage` call is
made in that branch. Matches the blocker description exactly.

**Blocker 3 — `scripts/audit-raw-claude.sh` missing** FIXED.
Script was created and made executable. Scans `lib/ stages/ tekhton.sh
tekhton-legacy.sh`, allowlists `lib/quota_probe.sh`, greps for `claude` in
command position using the documented pattern, exits 0 (clean) or 1 (findings
present), and prints one `file:line:matched` line per finding. Matches m20
design requirements.
