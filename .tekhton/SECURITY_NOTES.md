# Security Notes

Generated: 2026-05-24 23:55:09

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A01] [internal/finalize/clear_state.go:tekhtonDir] fixable:yes — `tekhtonDir()` reads `TEKHTON_DIR` from the environment and, for relative values, calls `filepath.Join(in.ProjectDir, v)` without rejecting `..` components. A crafted env var such as `TEKHTON_DIR=../../tmp` would direct the sentinel read to a path outside the project directory. Mitigation: call `filepath.Clean()` on the resolved path and verify it retains `in.ProjectDir` as a prefix before returning it. Note: the identical unvalidated pattern exists throughout the bash codebase (`lib/finalize_commit.sh`, `stages/intake.sh`); `tekhtonDir()` merely centralises rather than worsens it.
