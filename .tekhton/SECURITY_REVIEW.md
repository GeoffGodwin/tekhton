## Summary
m36.1 ports `stages/architect.sh` to Go (`internal/stages/architect/`) and m36.2 ports `lib/intake_helpers.sh` + `lib/intake_verdict_handlers.sh` to `internal/intake/` with a transition Cobra shim (`cmd/tekhton/intake.go`). Both ports follow established patterns: subprocess calls use `exec.CommandContext` argv arrays, file writes use atomic tmpfile+rename, temp files use `os.CreateTemp` (0600), and SHA-256 content hashing uses `crypto/sha256`. One low-severity finding carries forward from m36.1 (JSON injection in `tekhton-legacy.sh`), and one new low-severity finding appears in m36.2.

## Findings
- [LOW] [category:A03] [tekhton-legacy.sh:1058] fixable:yes — `${TASK:-architect-audit}` is interpolated verbatim into a JSON heredoc (`"task":"${TASK:-architect-audit}"`). A task string containing `"` or `\` produces malformed JSON; a crafted value like `foo","injected":"true` inserts extra fields into the stage request passed to the Go binary. Exploitability is very low (requires env-var control in a local developer tool). Fix: replace the heredoc with `jq -n --arg t "${TASK:-architect-audit}" --arg r "$result_file" '{proto:"tekhton.stage.request.v1",stage:"architect",task:$t,result_file:$r}'`.
- [LOW] [category:A03] [cmd/tekhton/intake.go:359] fixable:yes — `intakeStateSentinel` writes a TSV row where the `task` field is set verbatim from `os.Getenv("TASK")`. A task string containing literal tab characters would corrupt the field-split in `_intake_forward_state` (`IFS=$'\t' read -r _stage _exit _args _task _msg _ms`), causing incorrect values to be written to pipeline state on resume. Fix: escape or strip tab characters from all TSV fields before joining, e.g. `strings.ReplaceAll(task, "\t", " ")`.

## Verdict
FINDINGS_PRESENT
