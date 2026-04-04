# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-03 | "M56"] `preflight_services.sh` is 493 lines (exceeds 300-line ceiling). The ACP documents why this was necessary (preflight.sh was already 607 lines), so the split is correct — but if this file grows further, consider splitting inference (`_pf_infer_*`) from probing/reporting.
- [ ] [2026-04-03 | "M56"] `ARCHITECTURE.md` needs a `lib/preflight_services.sh` entry in the Layer 3 library listing. The ACP explicitly flags this but no update was made in this milestone.
- [ ] [2026-04-03 | "M56"] `docker info &>/dev/null 2>&1` (preflight_services.sh:304) — `&>` already redirects both stdout and stderr to /dev/null; the trailing `2>&1` is redundant. Same pattern at line 375.
- [ ] [2026-04-03 | "M56"] `_probe_service_port`: the `timeout_s` parameter is only respected by the `nc` fallback; the `/dev/tcp` primary path carries no enforced timeout. Practically fine for localhost (ECONNREFUSED returns instantly), but the parameter is misleadingly named — a filtered port could block indefinitely on the primary path.
- [ ] [2026-04-03 | "M56"] `grep -oP` (PCRE) in `_preflight_check_dev_server` (preflight_services.sh:328, 342) won't work on macOS stock grep. This is consistent with the M55 precedent in `preflight.sh` and is not new debt, but the risk accumulates.
- [ ] [2026-04-03 | "[BUG] Fix MAX_ARG_STRLEN (128KB) limit when passing prompts as positional arguments to the `claude` CLI. On Linux, individual command-line arguments are capped at 131072 bytes. Planning prompts that embed design docs, codebase summaries, repo maps, and template content routinely exceed this, causing "Argument list too long" failures."] `lib/plan.sh` `_call_planning_batch`: No cleanup on SIGINT/SIGTERM — if the user interrupts while claude is running, `rm -f "$_prompt_file"` is never reached and the temp file persists in TMPDIR until OS cleanup. The file is PID-namespaced so no security concern, just minor litter. The FIFO path has a proper abort trap; this path lacks one. Log for a cleanup pass.
- [ ] [2026-04-03 | "[BUG] Fix MAX_ARG_STRLEN (128KB) limit when passing prompts as positional arguments to the `claude` CLI. On Linux, individual command-line arguments are capped at 131072 bytes. Planning prompts that embed design docs, codebase summaries, repo maps, and template content routinely exceed this, causing "Argument list too long" failures."] `tests/test_prompt_tempfile.sh` line 132: The `$(seq 1 200000)` python3 fallback for generating a large prompt word-splits 200000 arguments into `printf`, which could itself hit ARG_MAX on systems without python3. Not a real concern since python3 is a Tekhton dependency in practice, but the fallback could fail on the very class of system it's meant to protect.
(none)

## Resolved
