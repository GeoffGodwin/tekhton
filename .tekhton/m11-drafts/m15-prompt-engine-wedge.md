<!-- milestone-meta
id: "15"
status: "todo"
-->

# m15 — Prompt Template Engine Wedge

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 4 — fourth wedge. The m11 Path B spike surfaced the prompt engine as a port-or-bridge decision: re-implementing `lib/prompts.sh`'s `{{VAR}}` + `{{IF:VAR}}…{{ENDIF:VAR}}` engine in Go is ~150 LOC, and orchestrate (m12) currently shells back to bash for prompt rendering. m15 closes that round-trip. |
| **Gap** | `lib/prompts.sh::render_prompt` performs all template substitution. Every stage that wants a prompt rendered shells through it. Orchestrate's m12 port has to either keep the round-trip or stub renders inline; m15 makes the engine first-class Go. |
| **m15 fills** | (1) `internal/prompt` package owning `Render(template, vars)` — `{{VAR}}` substitution + `{{IF:VAR}}…{{ENDIF:VAR}}` conditionals + nested-block handling. Byte-for-byte identical output to bash for the canonical prompt set. (2) `tekhton prompt render --template <name> --vars-file vars.json` subcommand for bash callers. (3) Parity test against every `prompts/*.prompt.md` × every `lib/prompts.sh` test fixture. (4) Internal use: `internal/orchestrate` calls `prompt.Render` directly. |
| **Depends on** | m12 |
| **Files changed** | `internal/prompt/` (new), `cmd/tekhton/prompt.go` (new), `lib/prompts.sh` (shim rewrite), `scripts/prompt-parity-check.sh` (new) |
| **Stability after this milestone** | Stable. All template renders go through Go; bash callers see no behavior change. |
| **Dogfooding stance** | Cutover within milestone. |

---

## Design

### Goal 1 — Engine semantics

Bash `lib/prompts.sh` does:

1. `{{VAR}}` literal substitution (sed-style).
2. `{{IF:VAR}}` … `{{ENDIF:VAR}}` block — kept iff `$VAR` is non-empty.
3. Trim leading newline if `{{IF:VAR}}` block was on its own line.
4. Nested blocks supported (rare but used in `prompts/coder_rework.prompt.md`).

Go implementation: regex-based scanner, two-pass (substitute conditionals
first, then variables, then strip stray markers). Test against the bash
output for every prompt × variable combination in `tests/test_prompts*.sh`.

### Goal 2 — `tekhton prompt render` CLI

```
tekhton prompt render --template intake_scan --vars-file /tmp/intake_vars.json
```

Reads JSON variables, renders, prints to stdout. Used by bash stages that
haven't been ported (intake, coder, reviewer, tester). After m15 their
`render_prompt` calls go through this CLI instead of `lib/prompts.sh`'s
inline awk.

### Goal 3 — Parity guarantee

`scripts/prompt-parity-check.sh` runs every prompt template through both
the bash engine (`lib/prompts.sh` at HEAD~1) and the Go engine (HEAD)
with a fixed variable set, asserting byte-for-byte identical output.
Fixtures cover empty-var, missing-var, nested-block, and trim-newline
edge cases.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/prompt/` | Create | Engine + tests. ~250-350 LOC. |
| `cmd/tekhton/prompt.go` | Create | `prompt render` subcommand. ~100 LOC. |
| `lib/prompts.sh` | Modify | Rewrite as ~50-line shim that invokes `tekhton prompt render`. |
| `scripts/prompt-parity-check.sh` | Create | Byte-for-byte parity gate. ~150 LOC. |

---

## Acceptance Criteria

- [ ] `tekhton prompt render --template <name> --vars-file <vars.json>` produces byte-for-byte identical output to `bash -c 'source lib/prompts.sh; render_prompt <name>'` (with the same vars exported) for every template under `prompts/`.
- [ ] `lib/prompts.sh` is ≤ 60 lines.
- [ ] Every `prompts/*.prompt.md` template renders without producing stray `{{...}}` markers in the Go output.
- [ ] Nested `{{IF:VAR}}` blocks render correctly (covered in `tests/test_prompts_nested.sh` if it exists, otherwise added).
- [ ] `internal/prompt` coverage ≥ 80%.
- [ ] `scripts/prompt-parity-check.sh` exits 0 against the full prompt × fixture matrix.
- [ ] `bash tests/run_tests.sh` passes; existing prompt-related tests adapted.

## Watch For

- **Byte-for-byte parity is mandatory.** Prompts feed agents — a single character of difference (a stray newline, a different trim point) can change agent behavior. The parity script's exit code is the gate; do not relax.
- **Don't add new template features.** The bash engine has exactly two: `{{VAR}}` and `{{IF:VAR}}`. Adding `{{ELSE}}` or loops belongs in a separate milestone, not m15.
- **Variable lookup is bash globals today.** The Go engine takes a `map[string]string`; the bash shim builds the map from the current environment + an explicit allowlist. Don't introduce a wildcard env-vars-as-template-vars footgun.
- **The trim-newline rule is subtle.** Bash strips one leading newline when a `{{IF:VAR}}` block consumes a whole line. Replicate exactly; the parity gate will catch deviations.

## Seeds Forward

- **m17 — error taxonomy:** template parse errors join the typed error set as `prompt.ErrUnclosedBlock`, etc.
- **In-process orchestrate render:** m12's orchestrate loop renders prompts in-process (no CLI hop) once m15 lands. Updates m12's `internal/orchestrate` to import `internal/prompt`.
- **Stage ports (Phase 5):** intake / coder / reviewer / tester all consume rendered prompts. After m15 their bash stages call `tekhton prompt render`; after their stage port (Phase 5) they call `prompt.Render` directly.
- **V5 prompt versioning:** if V5 introduces per-provider prompts, `internal/prompt` is the natural place for the dispatch logic. Out of scope for m15.
