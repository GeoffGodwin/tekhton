## Summary

m22 ports the preflight subsystem (six bash files deleted) into a clean Go package (`internal/preflight`). The code is a faithful translation: file I/O uses Go's standard library, port probing is always localhost-only, subprocess execution is limited to hardcoded command strings and external tool invocations (`docker`, `node`, `rustc`, etc.), and all file writes use atomic tmpfile+rename. No authentication, cryptography, or network communication beyond localhost TCP probing is involved. Three low-severity observations are noted.

## Findings

- [LOW] [category:A03] [internal/preflight/helpers.go:174] fixable:yes — `tryFix` passes `command` directly to `exec.Command("bash", "-c", command)`. All current call sites supply hardcoded literals ("npm install", "npx playwright install", etc.), so there is no injection in the current code. However, the unexported function signature gives no indication that `command` must be a literal; a future caller that interpolates config-derived input (e.g. a user-supplied package name) would silently introduce command injection. Consider adding a comment asserting the invariant or changing the signature to accept `[]string` args.

- [LOW] [category:A01] [internal/preflight/ui_audit.go:144-258] fixable:yes — `PREFLIGHT_BAK_DIR` (operator-set in pipeline.conf) controls both where config backup files are written and which directory `trimBackupDir` deletes regular files from. If a pipeline.conf is crafted with `PREFLIGHT_BAK_DIR=/some/sensitive/path`, the backup write and the file-trim loop would operate there. The risk is limited because pipeline.conf is controlled by the project operator, not an end-user. Mitigation: clamp the resolved `bakDir` to a subtree of `ProjectDir` and return a `failF` finding if the path escapes.

- [LOW] [category:A05] [internal/preflight/ui_audit.go:63-71] fixable:yes — `setUIEnvExports` mutates four `PREFLIGHT_UI_*` process-level env vars via `os.Setenv`. Because these vars are readable by any subprocess spawned by the parent process, a rule name or filename containing shell-special characters could influence downstream bash subprocesses that expand those variables unquoted. The values are constrained to the string `"PW-1"` / `"JV-1"` / `filepath.Base(cfg)` (known config file names), so the current risk is negligible; note it in case future rules introduce more dynamic content.

## Verdict
CLEAN
