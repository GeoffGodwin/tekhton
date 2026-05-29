## Summary

The m28.1 change set replaces a broken `python -m serena` invocation with the
`start-mcp-server` console-script form, adding `_SERENA_BIN` resolution in
`lib/mcp.sh` and matching sed substitution in `tools/setup_serena.sh`. This
cycle's net diff is a `VERSION` reset only; the substantive surface was landed
in prior commits. The code operates entirely in the developer's local
environment (no network-exposed services, no user authentication paths). No
critical or high-severity issues found. Three low/medium observations are noted
below, all pre-existing patterns in the codebase rather than regressions
introduced by m28.1.

## Findings

- [MEDIUM] [category:A08] [tools/setup_serena.sh:107] fixable:no — Serena is cloned from `https://github.com/oraios/serena.git` with `--depth 1` and no commit SHA pin or signature verification. A compromised upstream or DNS spoofing attack would install malicious code into the developer's environment. Mitigation options require either pinning a specific commit hash (breaks auto-update) or verifying a release checksum — both require a design decision that is out of scope for m28.1.

- [LOW] [category:A03] [lib/mcp.sh:144-149] [tools/setup_serena.sh:245-250] fixable:yes — The sed substitution uses `|` as the delimiter across both files. If any substituted value (`PROJECT_DIR`, `_SERENA_BIN`, `SERENA_LANGUAGE_SERVERS`) contains a literal `|`, the sed expression becomes syntactically malformed, producing a corrupt JSON config file. Paths cannot normally contain `|` on POSIX/Windows filesystems, but `SERENA_LANGUAGE_SERVERS` (from pipeline.conf) is user-controlled text. Impact is config corruption, not code execution. Fix: validate that `SERENA_LANGUAGE_SERVERS` contains only safe characters before substitution, or use `python -c 'import json, sys; ...'` for JSON generation instead of sed.

- [LOW] [category:A03] [tools/setup_serena.sh:245-250] [lib/mcp.sh:144-149] fixable:yes — Path values injected into the JSON template via sed are not JSON-escaped. A `PROJECT_DIR` or `SERENA_DIR` containing `"` or `\` produces malformed JSON. Impact is config parse failure by Claude CLI (not exploitable). Fix: use `jq` or a Python one-liner for JSON-safe output rather than raw sed substitution.

## Verdict

FINDINGS_PRESENT
