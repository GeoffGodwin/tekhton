## Summary
M21 ports the finalize orchestrator and 8 hook bodies from Bash to Go, introducing `internal/finalize/`, `cmd/tekhton/finalize.go`, `lib/finalize_shim.sh`, and `lib/finalize_core_hooks.sh`. The change is a faithful line-for-line port with no new attack surface. Go hooks use stdlib file I/O without shell exec; the bash shim dispatcher applies two-layer whitelist validation (case statement + `declare -f`) before dynamic function dispatch; all shell variables in new bash files are properly quoted; git and subprocess invocations use argument-list forms rather than shell interpolation. No critical or high severity issues found.

## Findings
- [LOW] [category:A05] [internal/finalize/archive_reports.go:118, internal/finalize/archive_milestone.go:119] fixable:yes — `absoluteUnder` does not sanitize `..` components from relative paths and passes absolute env-var paths (e.g. `CODER_SUMMARY_FILE`, `MILESTONE_ARCHIVE_FILE`) through unchanged. A crafted env value such as `MILESTONE_ARCHIVE_FILE=/etc/shadow` or `CODER_SUMMARY_FILE=../../outside/secret` would be followed without complaint. Exploitable only by a process that already controls the pipeline environment — not reachable from external user input — so impact is low. Suggested fix: call `filepath.Clean` on every resolved path and, for relative inputs, assert the cleaned path has `projectDir` as a prefix.

## Verdict
CLEAN
