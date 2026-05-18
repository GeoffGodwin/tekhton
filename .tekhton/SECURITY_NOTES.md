# Security Notes

Generated: 2026-05-18 02:40:47

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A05] [internal/finalize/archive_reports.go:118, internal/finalize/archive_milestone.go:119] fixable:yes — `absoluteUnder` does not sanitize `..` components from relative paths and passes absolute env-var paths (e.g. `CODER_SUMMARY_FILE`, `MILESTONE_ARCHIVE_FILE`) through unchanged. A crafted env value such as `MILESTONE_ARCHIVE_FILE=/etc/shadow` or `CODER_SUMMARY_FILE=../../outside/secret` would be followed without complaint. Exploitable only by a process that already controls the pipeline environment — not reachable from external user input — so impact is low. Suggested fix: call `filepath.Clean` on every resolved path and, for relative inputs, assert the cleaned path has `projectDir` as a prefix.
