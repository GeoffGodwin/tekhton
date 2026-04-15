# Security Notes

Generated: 2026-04-14 11:38:45

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A03] [tests/test_human_workflow.sh:76] fixable:yes — `assert_exit_code()` uses `eval "$cmd"` to execute its command argument. All current call sites pass hardcoded string literals (e.g., `"pick_next_note ''"`, `"claim_single_note '$note'"`), so no external input can reach the eval. Risk is latent: a future contributor adding a test case that interpolates untrusted data into `$cmd` could introduce command injection. Prefer direct function calls or `bash -c "$cmd"` with explicit argument passing to remove the pattern.
