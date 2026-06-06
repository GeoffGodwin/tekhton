# JR Coder Summary — m37.1 Review Helpers and Parser

## What Was Fixed

- `internal/review/parser.go:122-125` — Deleted the dead `inlineVerdictRE` variable (3-line comment block + `var` declaration). The variable was declared but never referenced; `inlineVerdictFallback` uses `strings.Contains` priority ordering instead. The `regexp` import remains valid (used by `noneSentinelRE` and `acpRowRE`). Fixes the `staticcheck U1000` / `golangci-lint` violation per CLAUDE.md Rule 3.

## Files Modified

- `internal/review/parser.go`
