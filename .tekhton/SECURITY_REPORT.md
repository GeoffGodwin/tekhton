## Summary

The m41 change set introduces file-reading helpers (sentinel reader, milestone file glob fallback) and removes a false-positive commit-gate trip. No authentication, cryptography, network I/O, or external user-supplied input is involved. All file I/O operates on pipeline-internal state under `MILESTONE_DIR` and `TEKHTON_DIR`, with values sourced from trusted pipeline configuration. Two low-severity hardening gaps were identified; neither is exploitable without prior write access to project-local files.

## Findings

- [LOW] [category:A01] [lib/milestone_window.sh:111-152] fixable:yes — `_read_milestone_file` constructs file paths from `$id` without validating it is free of path-traversal sequences (`../`). A manifest entry with a crafted id like `m../../sensitive-file` would cause `cat` to read an arbitrary `.md`-suffixed file relative to `MILESTONE_DIR` and surface its contents in `MILESTONE_BLOCK`. Exploitability is low: requires prior write access to the manifest or DAG arrays, and exfiltrated content is only exposed to the AI agent context, not executed or transmitted externally. Fix: add `[[ "$id" =~ ^m[0-9]+(\.[0-9]+)?(-[A-Za-z0-9_-]+)?$ ]] || return 0` at the top of `_read_milestone_file` before any path construction.
- [LOW] [category:A03] [lib/finalize_commit_sentinel.sh:41-53] fixable:yes — `_final_check_reason_read` returns the raw second line of `.tekhton/.final_check_result` (after stripping the `# ` marker) without filtering non-printable characters. `_hook_commit` embeds this value directly in a `warn` call (`lib/finalize_commit.sh:189`). If the sentinel file were tampered with (requires write access to the project `.tekhton/` directory), a crafted reason string could inject terminal escape sequences into operator output. Fix: pipe `raw` through `tr -cd '[:print:]'` before the `printf` return.

## Verdict

FINDINGS_PRESENT
