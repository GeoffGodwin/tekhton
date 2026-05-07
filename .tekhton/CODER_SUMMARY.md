# Coder Summary — m15 Prompt Template Engine Wedge

## Status: COMPLETE

## What Was Implemented

Phase 4 wedge — port the prompt template engine from `lib/prompts.sh` into a
Go package, replace the bash engine with a thin shim, and add an acceptance
gate that asserts byte-for-byte parity across every prompt template.

- **`internal/prompt/`** — new Go package owning `Render(promptsDir, name,
  vars)` and `RenderString(template, vars)`. Implements `{{VAR}}` substitution
  + line-based `{{IF:VAR}}…{{ENDIF:VAR}}` conditional handling. The trailing-
  newline normalization (`TrimRight + "\n"`) replicates the bash `$(cat)` /
  `echo` pipeline so multi-line variable values do not double up. The `TASK`
  variable is special-cased: non-empty values are wrapped in `--- BEGIN/END
  USER TASK ---` delimiters, mirroring the prompt-injection mitigation that
  was inline in the bash engine. `EnvVars()` returns a `map[string]string`
  view of `os.Environ()` so the CLI can pass the calling shell's variables
  through directly. Sentinel: `ErrTemplateNotFound`.
- **`cmd/tekhton/prompt.go`** — new Cobra subcommand `tekhton prompt render
  --template <name> [--prompts-dir DIR] [--vars-file vars.json]`. Prompts dir
  resolves in priority `--prompts-dir` > `$TEKHTON_PROMPTS_DIR` >
  `$TEKHTON_HOME/prompts`. With `--vars-file` the binary parses a flat JSON
  `{string: string}` map; without it, the process environment is used. Wired
  into `newRootCmd()` in `cmd/tekhton/main.go`. Exit codes match the project
  conventions: `0` success, `exitNotFound` (1) for missing templates,
  `exitUsage` (64) for flag/parse errors.
- **`lib/prompts.sh`** — rewritten as a 55-line shim (under the 60-line wedge
  ceiling). `render_prompt(name)` finds the template, exports every
  `{{VAR}}` / `{{IF:VAR}}` placeholder name so the subprocess can read it via
  `os.Environ`, resolves the `tekhton` binary path (`$TEKHTON_BIN`,
  `$TEKHTON_HOME/bin/tekhton`, then `$PATH`), and execs `tekhton prompt
  render`. Sources `lib/prompts_io.sh` so widely-used file-content helpers
  remain reachable through the same source line every existing caller uses.
- **`lib/prompts_io.sh`** — new sibling file holding `_safe_read_file`,
  `_wrap_file_content`, and `load_intake_template_vars` — the bash helpers
  that hung off the old `lib/prompts.sh` and are sourced by ~10 callers
  (`lib/context_cache.sh`, `lib/replan_brownfield.sh`, `lib/clarify.sh`,
  …). Pulling them out keeps the shim under the wedge ceiling without
  breaking those callers, since `lib/prompts.sh` re-sources this file on
  every load.
- **`scripts/prompt-parity-check.sh`** — new acceptance gate. Embeds a frozen
  copy of the pre-m15 bash `render_prompt` (clearly marked DO NOT MODIFY)
  and diffs its output against `tekhton prompt render` for every template
  under `prompts/` (45 templates) across three variants — `empty` (every
  referenced var unset), `set` (every var assigned a deterministic stand-in,
  TASK gets a multi-line value to verify wrapping), and `mixed` (alternating
  set/unset) — plus four targeted edge-case fixtures covering the m15 Watch
  For list (empty-var, missing-var, nested-block via distinct vars,
  trim-newline). Pass `--use-fallback` to skip the Go build for smoke runs.
- **`internal/prompt/prompt_test.go`** — Go unit tests covering: variable
  substitution (single, missing, empty, multi-line, trailing-newline-in-
  value, repeated placeholder), TASK wrapping (positive, empty, adversarial-
  marker), conditional blocks (10 cases including non-nested-same-var,
  distinct-var nesting both kept/inner-empty/outer-empty, inline markers,
  vars inside kept blocks), trailing-newline normalization, empty template,
  conditional runaway protection, file-not-found error, end-to-end Render
  via tempdir, EnvVars edge cases. Coverage 95.8%.
- **`cmd/tekhton/prompt_test.go`** — CLI tests covering: `resolvePromptsDir`
  precedence (explicit > env > home > error), `loadPromptVars` (env, JSON
  file, empty file, missing file, malformed JSON), and the `prompt render`
  subcommand happy/edge paths (env passthrough, vars-file, TASK wrapping,
  template-missing → `exitNotFound`, missing `--template` flag → `exitUsage`,
  bad JSON vars-file → `exitUsage`, conditional blocks both var-set and
  var-empty).
- **`ARCHITECTURE.md`** — updated `lib/prompts.sh` entry, added
  `lib/prompts_io.sh`, `internal/prompt/`, `cmd/tekhton/prompt.go`, and
  `scripts/prompt-parity-check.sh` entries.
- **`CLAUDE.md`** — repository layout updated to mark `prompts.sh` as the m15
  shim and add `prompts_io.sh`.

## Architecture Decisions

- **Helpers extracted, not deleted.** `_safe_read_file` and
  `_wrap_file_content` had ~10 non-prompt callers across `lib/`. Deleting
  them would have spread the wedge into unrelated subsystems and violated
  CLAUDE.md Rule 10 (no feature redesign during ports). Extracting them into
  `lib/prompts_io.sh` and re-sourcing from the shim keeps every existing
  call site working byte-for-byte while the engine itself moves to Go.
- **Env-passthrough rather than allowlist.** The m15 milestone Watch For
  warned about a "wildcard env-vars-as-template-vars footgun." The chosen
  shape is safer than an allowlist: the engine only consumes variable names
  that actually appear as `{{NAME}}` placeholders in the template. Even
  though `os.Environ()` carries the full process environment, an unrelated
  variable like `PATH` only leaks into a render if a template references
  `{{PATH}}` — and no template does. The allowlist would require enumerating
  148 placeholder names today and growing the list with every new prompt.
- **Frozen oracle inside the parity script.** The milestone phrasing
  ("`lib/prompts.sh` at HEAD~1") was satisfied by embedding a verbatim copy
  of the pre-m15 `render_prompt` body inside `scripts/prompt-parity-check.sh`
  rather than depending on `git show HEAD~1:lib/prompts.sh`. This makes the
  gate runnable on any checkout state (pre-merge, post-merge, tagged
  release) and CI-friendly. The frozen copy is clearly marked DO NOT MODIFY
  so future maintainers don't drift it out of step with reality.

## Files Modified

- `internal/prompt/prompt.go` (NEW) — Go template engine, 214 lines.
- `internal/prompt/prompt_test.go` (NEW) — 313 lines, 95.8% coverage.
- `cmd/tekhton/prompt.go` (NEW) — Cobra subcommand, 120 lines.
- `cmd/tekhton/prompt_test.go` (NEW) — 265 lines.
- `cmd/tekhton/main.go` — added `cmd.AddCommand(newPromptCmd())`.
- `lib/prompts.sh` — rewritten as 55-line shim (was 170 lines).
- `lib/prompts_io.sh` (NEW) — extracted file-content helpers, 69 lines.
- `scripts/prompt-parity-check.sh` (NEW) — parity gate, 294 lines.
- `ARCHITECTURE.md` — updated `lib/prompts.sh` entry and added five new
  entries (`lib/prompts_io.sh`, `internal/prompt/`, `cmd/tekhton/prompt.go`,
  `scripts/prompt-parity-check.sh`).
- `CLAUDE.md` — repository layout updated.

## Verification

- `bash scripts/prompt-parity-check.sh` — passes: 45 prompts × 3 variants +
  4 edge-case fixtures all match byte-for-byte.
- `go test ./internal/prompt -cover` — passes; coverage 95.8% (≥ 80% target).
- `go test ./...` — passes across all 11 Go packages.
- `go vet ./...` — clean.
- `shellcheck tekhton.sh lib/*.sh stages/*.sh scripts/*.sh` — clean.
- `bash tests/run_tests.sh` — 497 shell tests pass, Python tests pass, Go
  tests pass.
- `wc -l lib/prompts.sh` — 55 lines (≤ 60-line wedge ceiling).

## Acceptance Criteria

- [x] `tekhton prompt render` produces byte-for-byte identical output to the
  legacy bash engine for every template under `prompts/` (parity script
  exits 0 across 45 × 3 + 4 fixtures).
- [x] `lib/prompts.sh` is ≤ 60 lines (55 lines).
- [x] Every `prompts/*.prompt.md` template renders without producing stray
  `{{...}}` markers in the Go output (parity gate would diff against the
  bash output if any markers leaked).
- [x] Nested `{{IF:VAR}}` blocks render correctly (covered by
  `TestRenderString_ConditionalBlocks` cases `nested blocks via distinct
  vars, …` and the `nested_kept` edge fixture in the parity script).
- [x] `internal/prompt` coverage ≥ 80% (95.8%).
- [x] `scripts/prompt-parity-check.sh` exits 0 against the full prompt ×
  fixture matrix.
- [x] `bash tests/run_tests.sh` passes; existing prompt-related tests
  (`test_prompt_rendering.sh`, `test_prompt_templates.sh`,
  `test_prompt_isolation_guardrails.sh`) pass against the shim unchanged —
  no test adaptation needed because the rendered output is byte-identical.

## Human Notes Status

No `[ ]` notes targeted at this milestone — the M15 task was self-contained
in the milestone definition.

## Docs Updated

- `ARCHITECTURE.md` — see `## Files Modified` above.
- `CLAUDE.md` — repository layout entries.

The user-observable surface added by m15 (the `tekhton prompt render`
subcommand and the `internal/prompt.Render` Go API) is documented inline in
the source via package and function-level Go doc comments. Bash callers
continue to use `render_prompt` — its public contract is unchanged.
