<!-- milestone-meta
id: "24"
status: "todo"
-->

# m24 — Carried-Forward Non-Blocking Burn-Down: Redaction, Docs Rot, Ceiling Pressure

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | `.tekhton/NON_BLOCKING_LOG.md` has accumulated 69 open items. Most are minor, but several have been carried forward across multiple review cycles and include a MEDIUM security finding. Left unaddressed, the backlog grows past the point where the coder-prompt threshold mechanism can meaningfully surface it, and the security item ships in the stable promotion (m23). This milestone burns down the named carried-forward set before stable is promoted. |
| **Gap** | From `.tekhton/NON_BLOCKING_LOG.md` (2026-06-10 entries, all carried forward): (1) `internal/errors/redact.go` — `CODEX_API_KEY` values are not covered by `Redact()`; a provider error containing the key would land in logs/reports verbatim (MEDIUM security finding from the m17 security report, which includes the regex pattern). (2) `docs/v5-polyglot.md:255` — "Upgrading to m15 (this release)" milestone-scoped wording rots; needs version-number phrasing. (3) `lib/init_config_sections.sh` is at exactly 300 lines — the next addition breaches the hard ceiling; pre-emptively rehome headroom now rather than during an unrelated milestone. (4) The empty-chain and tier_used items in the log are owned by m19/m21 — this milestone closes the *log entries* once those land, and sweeps any remaining trivially-fixable open items (typo/wording class) in the same pass. |
| **m24 fills** | (1) Adds `CODEX_API_KEY` (and the generic `sk-`-style codex token shape per the m17 security report) to `internal/errors/redact.go` with table-test coverage, including the provider-error and stdout-tail paths. (2) Fixes the `docs/v5-polyglot.md` migration wording. (3) Splits `lib/init_config_sections.sh` below the ceiling by moving at least one cohesive emitter group into `lib/init_config_workspace.sh` or a new sibling, shellcheck-clean. (4) Audits the open NON_BLOCKING list: closes entries fixed here or by m19–m23 (checkbox → checked with a pointer to the fixing milestone), and re-files anything that has grown into real scope as a Drift Observation instead of a silent checkbox. |
| **Depends on** | m19, m21 |
| **Files changed** | `internal/errors/redact.go`, `internal/errors/redact_test.go`, `docs/v5-polyglot.md`, `lib/init_config_sections.sh`, `lib/init_config_workspace.sh` (or new sibling), `.tekhton/NON_BLOCKING_LOG.md` |

---

## Design

### Sequencing note

Depends on m19/m21 only for log-entry closure honesty (their items must
actually be fixed before being checked off). The redaction fix is
independent and urgent — if m19–m21 slip past the cutover window, split
the `redact.go` change out as a standalone hotfix milestone rather than
reordering m24 ahead of its manifest dependencies.

### Goal 1 — Codex credential redaction

`internal/errors/redact.go::Redact()` currently covers the Anthropic
credential shapes. Add the `CODEX_API_KEY=<value>` env-assignment
pattern from the m17 security report (the report's fix line provides
exactly `CODEX_API_KEY=[^ \r\n]*`; retrieve it from the archived
report rather than improvising). The JSON-field and embedded-token
shapes below are new coverage designed in this milestone, not in the
report. Table tests
must cover: env-assignment form, JSON field form (`"api_key": "..."`),
and a token embedded mid-string in a provider error message; plus a
negative case proving the redactor doesn't eat the literal string
`CODEX_API_KEY` when no value follows (docs/log lines mention the name
legitimately).

### Goal 2 — docs rot fix

`docs/v5-polyglot.md:255`: replace "Upgrading to m15 (this release)"
with version-anchored wording ("Upgrading to 5.15.0 or later"). Scan
the same file for any other milestone-scoped phrasing introduced
m15–m18 and fix in the same pass.

### Goal 3 — `lib/init_config_sections.sh` headroom

Move one or more cohesive section-emitter functions into
`lib/init_config_workspace.sh` (if domain-appropriate) or a new
`lib/init_config_sections_extra.sh`, leaving `init_config_sections.sh`
comfortably under the ceiling (target ≤270 lines). Preserve sourcing
order — check `lib/init.sh` / `lib/init_config.sh` for the source
chain and update it. Pure move, zero behavior change: `tekhton --init`
output for a fixture project must be byte-identical before/after
(assert via existing init tests or a temp-project diff in the test).

### Goal 4 — log hygiene pass

For each open entry in `.tekhton/NON_BLOCKING_LOG.md`: check the box
with a trailing `(fixed: m##)` annotation when the referenced issue is
verifiably closed by m19–m24; leave genuinely-open items untouched;
convert any item that has outgrown "non-blocking note" into a Drift
Observation via the standard drift flow. The log's format/markers must
stay parseable by the collector in the finalize path — do not
restructure the file.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/errors/redact.go` | Modify | CODEX_API_KEY + codex token-shape redaction patterns. |
| `internal/errors/redact_test.go` | Modify | Table cases: env, JSON, embedded, negative. |
| `docs/v5-polyglot.md` | Modify | Version-anchored migration wording. |
| `lib/init_config_sections.sh` | Modify | Shrink below ceiling via emitter extraction. |
| `lib/init_config_workspace.sh` | Modify | Receives extracted emitter(s) (or new `_extra` sibling created instead). |
| `.tekhton/NON_BLOCKING_LOG.md` | Modify | Close fixed entries with milestone annotations; escalate outgrown ones to drift. |

---

## Acceptance Criteria

- [ ] `Redact()` replaces the value in `CODEX_API_KEY=sk-test-1234567890abcdef` with the redaction placeholder while leaving the literal substring `CODEX_API_KEY` intact (test asserts both properties).
- [ ] `Redact()` redacts the token in a JSON form (`"CODEX_API_KEY": "..."`) and embedded mid-sentence in an error string (table tests pass).
- [ ] `docs/v5-polyglot.md` contains no occurrence of the phrase "this release" tied to a milestone number; the migration section references a `MAJOR.MINOR.PATCH` version.
- [ ] `lib/init_config_sections.sh` is ≤270 lines; `wc -l` asserted in a test or the existing length-ceiling check covers it.
- [ ] `tekhton --init` output for the init test fixture is byte-identical before and after the extraction (existing init tests pass unmodified; if none diff the full output, add the diff assertion).
- [ ] `shellcheck` passes with zero warnings on all touched `.sh` files.
- [ ] Every checked entry in `.tekhton/NON_BLOCKING_LOG.md` carries a `(fixed: m##)` annotation pointing at a landed milestone; the file still parses through the finalize collector (its test or a manual collector run passes).
- [ ] No regression: `go test ./internal/errors/...` and `bash tests/run_tests.sh` pass.

## Watch For

- **The redaction regex is in the m17 security report** — retrieve it from the archived report (git history of `.tekhton/SECURITY_REPORT.md` around the m17 commits) rather than improvising a new pattern.
- **Over-eager redaction** is a real failure mode: docs and tests legitimately contain the variable *name*; only values must be masked.
- **Init extraction is behavior-frozen:** if any emitter ordering changes the generated pipeline.conf section order, that's a behavior change — keep emit order identical.
- **Don't bulk-close the log.** 69 open items were not all reviewed here; only entries verifiably fixed by m19–m24 get checked. Honest bookkeeping beats a clean-looking file.
- **The NON_BLOCKING collector** (`internal/finalize/resolve_addressed_nonblocking.go`) may have format expectations — read it before editing the log file's structure.

## Seeds Forward

- **Stable promotion (m23):** the security redaction lands before the runtime that handles codex credentials is promoted.
- **Backlog cadence:** establishes the pattern of a small burn-down milestone per arc, keeping the non-blocking log below the prompt-threshold noise floor.
- **Provider-credential hygiene:** the token-shape table in redact_test.go is where future provider keys (qwen-local bearer tokens, etc.) get covered.
