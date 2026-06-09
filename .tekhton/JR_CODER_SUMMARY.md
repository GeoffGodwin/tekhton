## Changes Made

**File:** `internal/provider/codex/codex.go`

Fixed tempfile leak in `RunAgent`: `buildExecArgs` (via `makeOutputLastMessagePath`) creates a
`tekhton-codex-last-*.md` tempfile whenever `codex.output_last_message` is absent from
`ProviderSpecific`, but the old code never cleaned it up and never told the caller where it was.

**What changed:**

1. Added `"os"` import.
2. After `buildExecArgs` returns, scan `args` for the element following `--output-last-message`
   to recover `outPath`.
3. On the process-level error path (`runErr != nil`): call `os.Remove(outPath)` — the file
   won't be read, so remove it immediately rather than leak it.
4. On the success path: set `LastReportPath: outPath` in the returned `Result`. The caller now
   owns the file's lifecycle and m08 consumers can locate the output via `Result.LastReportPath`.
5. Updated the `RunAgent` doc comment to reflect that `LastReportPath` is now populated at m07.

**Why the caller-owns approach over defer-remove:**
The reviewer noted "the latter also unblocks m08 consumers" — m08 will read the file from
`LastReportPath` to parse JSON events. A `defer os.Remove` would delete the file before any
caller could read it. The caller-owns pattern is correct: the caller reads and then removes it.
For the error path (no caller to own it), we remove immediately.

## Items Not Touched

All non-blocking notes from the reviewer report (exec_test.go `requireBin` duplicate, flags.go
map iteration order, inline-config `=` guard, `--cd` path validation) were left untouched per
task scope ("fix only items under Simple Blockers").
