<!-- milestone-meta
id: "26"
status: "todo"
-->

# m26 — Human-Facing Terminal Output Regressions From the Go Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | The Ship-of-Theseus port to Go broke two human-facing terminal surfaces that worked in the V3 bash runtime. Both are interactive-TTY-only regressions invisible to the test suite (captured/non-TTY output is fine), so they slipped through every parity gate. A human operator currently cannot read informational command output and cannot use the live dashboard at all — the two things a human most relies on during a run. |
| **Gap** | (1) Informational/read-only commands clear the terminal on exit when stdout is a TTY, leaving a blank screen — observed with `tekhton --dag frontier` and `tekhton --help --all`, almost certainly all non-`run` subcommands. Output is correct when captured (non-TTY), so the culprit is TTY-gated terminal-control emission (suspected: an unconditional alt-screen-restore / `tput rmcup` / clear in a bash EXIT trap that fires even when no TUI sidecar was spawned, or in the dispatcher's cleanup path). (2) The TUI sidecar is broken since the Go port: it usually doesn't render, and when it does it is graphically glitched and does not refresh. Root cause is a Go-writer ↔ Python-reader schema drift across the `tui_status.json` seam (`internal/tui/status.go` writes vs `tools/tui_render.py` reads). |
| **m26 fills** | Goal 1: stop non-`run` commands from clearing the TTY — scope terminal-control setup/teardown to commands that actually spawn the sidecar, so `dag`, `help`, `manifest`, `config`, etc. leave their output on screen. Goal 2: reconcile the `tui_status.json` contract between the Go writer and the Python renderer (event shape, field names, nesting) and restore live refresh, so the sidecar renders correctly and updates on every tick during a `run`/`--complete`. Both ship with TTY-aware regression tests (pty-driven) so these never silently regress again. |
| **Depends on** | (none) |
| **Files changed** | `tekhton.sh`, `lib/sidecar_lifecycle.sh`, `internal/tui/status.go`, `internal/tui/state.go`, `tools/tui.py`, `tools/tui_render.py`, `tests/test_tty_no_screen_clear.sh` (new), `tests/test_tui_status_contract.sh` (new) |

---

## Design

> Two independent goals; either can land first. They are bundled because both
> are TTY-only terminal-output regressions from the V4 Go port and both touch
> the sidecar / terminal-control plumbing. If Goal 2 grows beyond a contract
> reconciliation into a sidecar rewrite, split it into its own milestone —
> do not let it hold Goal 1's small fix hostage.

### Goal 1 — Non-`run` commands must not clear the terminal on a TTY

Reproduction (on a real terminal, not captured):

```
tekhton --dag frontier      # screen clears, shows nothing
tekhton --help --all        # screen clears, shows nothing
```

Captured/non-TTY the same commands print correctly (`dag frontier` →
"--path or $MILESTONE_MANIFEST_FILE required"; `--help --all` →
"unknown flag: --all"), confirming the clear is TTY-gated, not a content bug.

Investigation leads (verify before fixing — do not assume):
- The Go binary is plain Cobra with **no** pager/alt-screen/styling deps
  (`go.mod` has no charmbracelet/fang/tcell/pager), and these commands are
  dispatched straight to the binary — so the clear is almost certainly
  **bash-side**, not Go.
- The sidecar spawn (`lib/sidecar_lifecycle.sh::_sidecar_spawn`) is correctly
  gated on TTY+venv+rich and run-flow only. The suspect is the **teardown**:
  an EXIT/INT/TERM trap that restores the screen (`tput rmcup`, `printf
  '\e[?1049l'`, or `clear`) unconditionally — i.e. without checking that
  `_TUI_ACTIVE == true`. On a TTY that trap fires for every command,
  including `dag`/`help`, clearing the screen the command just wrote to.
- Fix shape: guard every terminal-restore action behind the same
  `_TUI_ACTIVE`/sidecar-spawned predicate that guards spawn. A command that
  never entered the alternate screen must never exit it.

### Goal 2 — Reconcile the `tui_status.json` Go-writer ↔ Python-reader contract

Concrete drift already found (not exhaustive — audit the full field set):

| Field | Go writer (`internal/tui/status.go`) | Python reader (`tools/tui_render.py`) |
|-------|--------------------------------------|----------------------------------------|
| events | `RecentEvents []string` (list of strings) | iterates dicts: `ev.get("ts")`, `ev.get("level")` (`tui_render.py:247`) |
| agent state | `AgentStatus` → `agent_status` | reads `current_agent_status` (`tui_render.py:69,124`) |
| many panel fields | not present in flat `StatusV1` | reads `stage_label`, `current_substage_label`, `agent_model`, `stage_start_ts`, `agent_elapsed_secs`, `milestone`, `milestone_title`, `task`, `attempt`, `max_attempts`, `project_dir`, `stage_total` |

`tools/tui.py` already handles the nested `{proto, payload}` envelope
(`tui.py:72-76`), so check whether the renderer fields live in the
`payload` proto (`internal/tui/state.go::TUIStatusV1Payload`) and the
renderer is reading the wrong nesting level, vs. genuinely-missing fields.
Decide one canonical shape and make both sides agree; "not updating
regularly" suggests either the atomic writer (`lib/tui_liveness.sh`) isn't
bumping a field the renderer watches, or the tick reads a stale path.

Pick the authoritative direction (recommended: the Go writer's emitted
schema is canonical since it owns the state machine post-port; adapt
`tui_render.py`/`tui.py` to it, OR add the missing fields to the Go
emitter — whichever is fewer changes for the same rendered result).

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `tekhton.sh` | Modify | Gate terminal-restore/cleanup trap on sidecar-active predicate (Goal 1). |
| `lib/sidecar_lifecycle.sh` | Modify | Ensure teardown is symmetric with spawn — only restore screen if spawned (Goal 1). |
| `internal/tui/status.go` | Modify | Reconcile emitted field names/shapes to the renderer contract (Goal 2). |
| `internal/tui/state.go` | Modify | Payload/event-shape alignment if drift lives in the nested proto (Goal 2). |
| `tools/tui.py` | Modify | Read correct nesting level / canonical field names (Goal 2). |
| `tools/tui_render.py` | Modify | Consume the reconciled event + status shape (Goal 2). |
| `tests/test_tty_no_screen_clear.sh` | Create | pty-driven: assert no alt-screen/clear control bytes emitted by non-run subcommands. |
| `tests/test_tui_status_contract.sh` | Create | Feed a Go-emitted `tui_status.json` to the Python renderer; assert no exception + non-empty panels. |

---

## Acceptance Criteria

- [ ] Under a pseudo-tty, `tekhton dag frontier` and `tekhton --help` emit **no** alternate-screen-enter/exit (`\e[?1049h`/`\e[?1049l`), no `\e[2J` clear, and no `tput smcup/rmcup` sequence; the command's output text is still present on screen after exit. Asserted by `tests/test_tty_no_screen_clear.sh`.
- [ ] The same pty test covers at least three non-`run` subcommands (`dag`, `help`, `config`) and fails if any emits a screen-clear/alt-screen sequence.
- [ ] A `tui_status.json` produced by the Go writer (`tekhton tui start` + one `tekhton tui update`) is consumed by `tools/tui_render.py` without raising, and `_build_events_panel` renders the events (event objects expose the keys the renderer reads, e.g. `ts`/`level`). Asserted by `tests/test_tui_status_contract.sh`.
- [ ] The agent-status field name is consistent end-to-end: the value the Go writer emits is the value `tui_render.py` reads (no `agent_status` vs `current_agent_status` mismatch).
- [ ] A live smoke (`TUI_ENABLED=true` on a pty during a trivial run) shows the dashboard rendering and the events panel / turn counter advancing across at least two ticks — documented repro in the milestone close notes (manual, since live rendering isn't unit-testable).
- [ ] All new tests pass: `tests/test_tty_no_screen_clear.sh`, `tests/test_tui_status_contract.sh`.
- [ ] No regression in `tests/test_tui_lifecycle_invariants.sh`, `tools/tests/test_tui.py`, and `go test ./internal/tui/...`.

## Watch For

- **TTY-only repro:** the whole bug class is invisible without a real terminal or a pty harness. Use `script -qec '<cmd>' /dev/null` (or Python `pty`) in the tests; a plain `$(...)` capture will pass even against the broken code.
- **Symmetric setup/teardown:** the spawn path is already correctly gated — do not loosen it. The fix is making teardown obey the *same* gate, not adding new gates to spawn.
- **Nesting before fields:** `tui.py` handles a `{proto, payload}` envelope. Confirm whether renderer fields are missing vs. read at the wrong nesting level before changing the Go schema — a wrong call here doubles the work.
- **Canonical direction:** decide once whether Go-emitted or Python-expected schema is authoritative, write it down in the milestone, and make every change serve that decision. Mixed direction is how this drifted in the first place.
- **Don't widen scope to a TUI redesign:** this milestone restores parity with the V3 behavior. New TUI features wait (CLAUDE.md rule 10 — no feature redesign during/after ports without a separate milestone).

## Seeds Forward

- **Provider-cutover dogfood UX:** a working TUI is how the operator will watch the June-15 codex/qwen-local runs; this unblocks confident monitoring of `--complete` arcs.
- **pty test harness:** `tests/test_tty_no_screen_clear.sh` establishes a reusable pseudo-tty pattern for any future TTY-gated CLI behavior (pagers, prompts, spinners).
- **Status contract test:** `tests/test_tui_status_contract.sh` becomes the guard for every future change to the Go↔Python TUI seam, the same role the lifecycle-invariants test plays for stage ownership.
