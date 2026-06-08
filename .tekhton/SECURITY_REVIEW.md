## Summary
The m50 changes introduce a security-hardening feature: a pre-commit guard that prevents non-finalize pipeline stages from committing `MANIFEST.cfg`. The implementation spans a bash guard (`_check_manifest_write_guard` in `lib/finalize_commit.sh`), a Go sentinel writer (`writeFinalizeActiveSentinel` in `internal/finalize/orchestrator.go`), a Go observability banner (`emitManifestWriteAuditBanner` in `cmd/tekhton/run.go`), and a new bash helpers file (`lib/finalize_commit_helpers.sh`). The overall security posture of these changes is strong: git operations use `--` separators and properly quoted arrays, Go subprocess calls use `exec.Command` with hardcoded arguments (no shell interpolation), and sentinel file I/O uses standard library calls with appropriate permissions (`0o644`/`0o755`). One low-severity path-construction concern is noted.

## Findings
- [LOW] [category:A03] [lib/finalize_commit.sh:120-123] fixable:yes — `_check_manifest_write_guard` constructs `tekhton_dir` by joining `${PROJECT_DIR}` and `${TEKHTON_DIR:-".tekhton"}` without normalizing either for `../` traversal sequences. If `TEKHTON_DIR` were set to a value like `../../etc`, the sentinel path would escape the project directory. In practice both vars are pipeline-internal (set from `pipeline.conf`, not external user input), so the blast radius is limited to a misconfigured operator environment. Fix: apply `realpath --canonicalize-missing` or assert `[[ "$tekhton_dir" == "${PROJECT_DIR}"/* ]]` before use.

## Verdict
FINDINGS_PRESENT

---

# Code Review — m50

**Reviewer:** Code Review Agent  
**Cycle:** 1 of 3

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `cmd/tekhton/run.go` is at 820 LOC — 220 lines above the 600-line soft target. Pre-existing before m50; this milestone added ~60 lines to a file that was already over the soft ceiling. Scheduling a split is worth tracking.
- `_check_manifest_write_guard` fails safe when `writeFinalizeActiveSentinel` errors (no sentinel → guard blocks the write), and the Go helper already logs the write failure to `in.Log`. The operator UX gap is minor: no sentinel on disk means manual inspection can't distinguish "finalize is actively running" from "finalize sentinel write failed." Not a blocker; the log message is sufficient.

## Coverage Gaps
- `_is_path_allowed` in `lib/finalize_commit_staging.sh` is not tested for MANIFEST.cfg specifically. The guard intercepts regardless of the allowlist decision, so there is no correctness gap today. Worth a unit test if the allowlist logic changes in the future.

## Drift Observations
- `cmd/tekhton/run.go:820` — largest file in the Go tree. Natural split is a `run_autoadvance.go` sibling for the `runAutoAdvanceLoop` / `clearAutoAdvanceIterationState` / `emitAutoAdvanceCommitBanner` / `emitManifestWriteAuditBanner` / `headCommitTouchedManifest` cluster (~300 lines). Flag for the next cleanup pass before the file reaches the 1000-line hard ceiling.
