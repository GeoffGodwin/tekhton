## What Was Fixed

- `internal/errors/redact_test.go` — Added three table-driven test functions covering the required acceptance-criterion categories:
  - `TestRedact_EnvAssignment`: four cases — `CODEX_API_KEY=...`, `OPENAI_API_KEY=...`, `ANTHROPIC_API_KEY=...`, and a mid-string embedded variant. Each asserts the secret value is absent and the correct `[REDACTED]` form appears.
  - `TestRedact_APIKeyAssignment`: four cases of `api[_-]key=value` (both `_` and `-` separators, with/without spaces, embedded mid-line). Note: JSON colon-separator form (`"api_key":"value"`) is not handled by the current patterns — test coverage reflects the actual `=`-assignment contract.
  - `TestRedact_Negative`: four inputs that must produce no `[REDACTED]` marker — plain "apikey" word without `=`, a lowercase env var without `_API_KEY` suffix, a raw `req_` request ID, and a plain build-failure line.
  All new tests pass: `go test ./internal/errors/... ok`.

- `docs/v5-polyglot.md:255` — Removed `(this release)` from the migration heading.
  Before: `**Important:** Upgrading to m15 (this release) changes the implicit default.`
  After:  `**Important:** Upgrading to m15 changes the implicit default.`

## Files Modified

- `internal/errors/redact_test.go`
- `docs/v5-polyglot.md`
