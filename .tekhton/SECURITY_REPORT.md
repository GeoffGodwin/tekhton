## Summary
This change introduces a commit-decision sentinel (`.tekhton/.commit_decision`) that gates the `mark_done`, `cleanup_milestone`, and `clear_state` finalize hooks on whether the user actually committed. The sentinel is written by `_hook_commit` in `lib/finalize_commit.sh` using controlled string literals ("committed", "declined", "skipped"), read back in `internal/finalize/clear_state.go` via `commitWasApproved()`, and cleared at pipeline start in `stages/intake.sh`. No network I/O, authentication, cryptography, or user-supplied content written to files is involved. One low-severity path-traversal observation applies to the new `tekhtonDir()` Go helper, consistent with the pre-existing bash convention across the rest of the codebase.

## Findings
- [LOW] [category:A01] [internal/finalize/clear_state.go:tekhtonDir] fixable:yes — `tekhtonDir()` reads `TEKHTON_DIR` from the environment and, for relative values, calls `filepath.Join(in.ProjectDir, v)` without rejecting `..` components. A crafted env var such as `TEKHTON_DIR=../../tmp` would direct the sentinel read to a path outside the project directory. Mitigation: call `filepath.Clean()` on the resolved path and verify it retains `in.ProjectDir` as a prefix before returning it. Note: the identical unvalidated pattern exists throughout the bash codebase (`lib/finalize_commit.sh`, `stages/intake.sh`); `tekhtonDir()` merely centralises rather than worsens it.

## Verdict
FINDINGS_PRESENT
