## Summary
m28.2 adds `_probe_serena_startup()` — a 2-second `timeout`-guarded binary invocation that gates `start_mcp_server` before it sets `SERENA_ACTIVE`. The change surface is small: one new 9-line function in `lib/mcp.sh`, a 10-line probe gate in `start_mcp_server`, and test-stub updates in two test files. The probe is correctly implemented: the binary path is double-quoted, stdout/stderr are suppressed, and a hard timeout prevents hangs. No authentication, cryptography, user input handling, or network communication is introduced. The three low/medium findings from the m28.1 report (unpinned git clone, sed delimiter collision, unescaped JSON paths) remain pre-existing and are unchanged by this diff.

## Findings
None

## Verdict
CLEAN
