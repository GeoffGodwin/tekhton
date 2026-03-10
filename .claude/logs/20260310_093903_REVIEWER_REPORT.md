# Reviewer Report — Milestone 1: Foundation — CLI Flag, Library Skeleton, Project Type Selection

## Verdict
APPROVED

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `run_plan()` (plan.sh:84) prints "Project type '...' selected" and "Template resolved: ..." after `select_project_type()` already printed both via `success` and `log`. This is redundant output — the user sees the confirmation twice. Consider removing the duplicates from `run_plan()` (lines 99–102) and letting `select_project_type()` be the single source of truth for those messages.
- `select_project_type()` uses `read -r choice` directly from stdin with no `/dev/tty` fallback. This is fine for the interactive intent, but worth noting: if `--plan` is ever invoked with piped stdin (e.g., scripted testing), it will block silently. Not a problem now, but a natural edge case to handle in Milestone 6's state persistence work.

## Coverage Gaps
- None

## Drift Observations
- None

---

## Review Notes

**Shell quality:** `lib/plan.sh` passes `shellcheck` with zero warnings and `bash -n` syntax check. The absence of `set -euo pipefail` in `lib/plan.sh` is consistent with all other lib files in the project (they inherit the entry point's `set -euo pipefail` via source). No deviation from project convention.

**Architecture boundary:** The `--plan` early-exit block (tekhton.sh:168–175) exactly mirrors the `--init` pattern — sources only `lib/common.sh` and `lib/plan.sh`, calls `run_plan()`, exits 0. No execution pipeline files were modified.

**Acceptance criteria (all met):**
- 7 project types displayed in numbered menu ✓
- Valid selection resolves correct template path ✓
- Invalid selection shows warning and re-prompts ✓
- All 7 templates exist with `<!-- REQUIRED -->` markers and guidance comments ✓
- All new shell code passes `bash -n` ✓

**Pre-existing shellcheck issues in tekhton.sh** (SC2034 on TOTAL_TURNS/TOTAL_TIME/STAGE_SUMMARY, SC1091 on source paths) are not introduced by this milestone and are out of scope for this review.

**Architecture decisions assessed:**
- Parallel arrays for menu data (PLAN_PROJECT_TYPES / PLAN_PROJECT_LABELS): sensible choice. Deterministic order, direct slug-to-filename mapping, no external data dependency.
- `<!-- REQUIRED -->` markers in templates: clean forward-compatibility hook for Milestone 3 completeness checking. Grep-stable and unambiguous.
