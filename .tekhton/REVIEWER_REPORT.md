# Reviewer Report — m27.2 Defensive `${VAR:-default}` Sweep (Cycle 1)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
None

## Simple Blockers (jr coder)
None

## Non-Blocking Notes
- `tests/test_m84_static_analysis.sh:55` — `_strip_m27_defaults` uses `grep -v "${fname}}"` without `-F`; the `.` in filenames (e.g. `SCOUT_REPORT.md}`) is treated as a regex metachar rather than a literal period. Should be `grep -vF "${fname}}"`. Harmless in practice since no `SCOUT_REPORTXmd}` strings exist, but technically imprecise.
- AC8 (`tekhton --dry-run --milestone m27.3` env-capture check) was not exercised. The coder's substitution argument — that `audit-bash-env.sh` returning 0 is a strictly stronger guarantee — is sound, and no objection is raised. Noting for traceability since the milestone named it as an acceptance criterion.

## Coverage Gaps
None

## ACP Verdicts
- ACP: M84 "no literal filenames" rule — exemption for `${VAR:-LITERAL}` defaults — **ACCEPT** — The `_strip_m27_defaults` filter correctly identifies the `${VAR:-…/FILENAME.md}` form via the close-brace signature `FILENAME.md}`. Bare hardcoded references still fail. Rationale mirrors the existing `artifact_defaults.sh`/`config_defaults.sh` exemption; backward-compatible.

## Drift Observations
None
