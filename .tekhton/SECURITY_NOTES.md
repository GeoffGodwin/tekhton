# Security Notes

Generated: 2026-06-03 18:50:51

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A01] [lib/milestone_window.sh:131-132] fixable:yes — `_read_milestone_file` constructs glob patterns from `$id` without validating it is free of path-traversal sequences. A crafted id (e.g. `m../../secret`) passed through the DAG arrays would cause `cat` to read an arbitrary `.md`-suffixed file outside `MILESTONE_DIR` and surface its contents in `MILESTONE_BLOCK`. Exploitation requires prior write access to the manifest or `_DAG_IDS` arrays. Suggested fix: add `[[ "$id" =~ ^m[0-9]+(\.[0-9]+)?(-[A-Za-z0-9_-]+)?$ ]] || return 0` at the top of `_read_milestone_file` before any path construction.
- [LOW] [category:A03] [lib/finalize_commit_sentinel.sh:45-52] fixable:yes — `_final_check_reason_read` returns the raw content of line 2 of `.tekhton/.final_check_result` after stripping the `# ` comment marker, with no filtering of non-printable characters. `_hook_commit` embeds this value in a `warn` call (finalize_commit.sh:189). A crafted sentinel file containing ANSI escape sequences could inject control characters into operator terminal output. Exploitation requires write access to the `.tekhton/` directory. Suggested fix: pipe `raw` through `tr -cd '[:print:]'` before the final `printf`.
