## Summary
m36.1 ports `stages/architect.sh` (414 LOC) to Go (`internal/stages/architect/`). The Go code follows the established stage-port pattern cleanly: subprocess execution uses `exec.CommandContext` with argv arrays (no shell interpolation), temp files use `os.CreateTemp` (0600 by default), and file paths flow through `filepath.Join`. One low-severity issue exists in the new bash shim in `tekhton-legacy.sh`: the `TASK` env var is interpolated directly into a JSON heredoc without escaping, which can produce malformed or injected JSON when the task string contains double-quotes or backslashes.

## Findings
- [LOW] [category:A03] [tekhton-legacy.sh:1057] fixable:yes — `${TASK:-architect-audit}` is interpolated verbatim into a JSON heredoc (`"task":"${TASK:-architect-audit}"`). A task string containing `"` or `\` produces malformed JSON; a crafted value like `foo","injected":"true` inserts extra fields into the stage request passed to the Go binary. Exploitability is very low (requires env-var control in a local developer tool), but the heredoc should emit the task field via a safe JSON encoder — either `jq -n --arg t "${TASK:-architect-audit}" '{proto:…,task:$t,…}'` or the same `printf '%s' … | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'` escaping used elsewhere in the codebase.

## Verdict
FINDINGS_PRESENT
