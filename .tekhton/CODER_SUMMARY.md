# Coder Summary

## Status: COMPLETE

## What Was Implemented

m29.1 (Detect Core + Report) — the bulk of this milestone was already
implemented during prior pipeline runs (engine, languages detector,
report formatter, Cobra surface, fixtures, baselines, parity gate, and
readonly contract test). This run resolved the final acceptance gate:
shellcheck against the parity test + baseline capture script returned
exit 1 because of SC1091 (info-level "not following" warnings on the
runtime-sourced files). Added explicit `# shellcheck disable=SC1091`
directives to both files so shellcheck exits 0 cleanly.

Final verification on m29.1's acceptance gates this run:
- `go test ./internal/detect/... ./cmd/tekhton/...` — passes (cached + fresh).
- `bash tests/test_detect_parity.sh` — 3/3 fixtures byte-identical to
  baselines (monorepo-pnpm, polyglot-services, ai-heavy-mess).
- `bash scripts/capture-detect-baselines.sh` — re-runs cleanly,
  `git diff` against baselines is empty (capture is stable).
- `bash scripts/audit-bash-env.sh` — exits 0.
- `shellcheck tests/test_detect_parity.sh scripts/capture-detect-baselines.sh`
  — exits 0 after the SC1091 disable directives landed this run.
- No `lib/detect*.sh` file is modified or deleted —
  `git diff --stat HEAD -- lib/detect` is empty.

## Root Cause (bugs only)
N/A — milestone implementation, not a bug fix. The Tester report
identified no bugs; the Reviewer report (APPROVED_WITH_NOTES) had no
blockers.

## Files Modified

- `tests/test_detect_parity.sh` — added `# shellcheck disable=SC1091`
  on the `source` line for `tests/lib/parity.sh` so shellcheck's
  default-severity gate exits 0.
- `scripts/capture-detect-baselines.sh` — replaced nine
  `# shellcheck source=../lib/detect*.sh` directives with
  `# shellcheck disable=SC1091` siblings (shellcheck's path resolver
  can't follow the runtime-computed `${TEKHTON_HOME}` prefix even with
  the `source=` hint, so it always emitted SC1091).

No new files. No files deleted. No `lib/detect*.sh` changes. No bash
caller changes.

## Human Notes Status

The CLARIFICATIONS.md block in the task header carried several
unrelated topics (Watchtower dashboard, NON_BLOCKING_LOG, init flow,
human-notes consistency) but none of those clarifications applied to
the m29.1 scope, which is the detect engine port. No human notes
required action this run.

## Observed Issues (out of scope)

- `tests/test_drift_prompts.sh` fails on `theseus/Phase2` HEAD
  (verified by `git stash && bash tests/test_drift_prompts.sh`). The
  `assert_contains "Coder ACP section present"` predicate does not
  find "Architecture Change Proposals" in the rendered coder prompt
  output. Manual render *does* include the string (count 3), so the
  failure looks like a test harness issue — the test's TMPDIR-based
  `PROJECT_DIR` likely interacts poorly with the Go-shimmed
  `render_prompt` engine. Pre-existing; not introduced by m29.1; out
  of scope for this milestone. Flagging for the drift / prompt-engine
  arc owner.

## Architecture Change Proposals

None. m29.1 followed the design as authored — engine + report
formatter + languages detector + parity gate, all in Go under
`internal/detect/` with no bash subsystem mutation. The Architecture
doc already carries `internal/detect/` and `cmd/tekhton/detect.go`
entries at the correct depth (verified via grep).

## Files Modified (auto-detected)
- `.claude/project_version.cfg`
- `.tekhton/CODER_SUMMARY.md`
- `VERSION`
- `scripts/capture-detect-baselines.sh`
- `tests/test_detect_parity.sh`
- `tests/test_m33_milestone_structure.sh`
