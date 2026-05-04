# M99 — Output Bus Core + Context Store
<!-- milestone-meta
id: "99"
status: "done"
-->

## Overview

Tekhton's run-context state (mode, attempt counter, task, milestone) is tracked in
scattered globals across `tekhton.sh`, `lib/orchestrate.sh`, and three separate fix
loops. The TUI sidecar reads these opportunistically — including `PIPELINE_ATTEMPT`
(line 107 of `lib/tui_helpers.sh`), a variable that is **never set anywhere** in the
codebase and always evaluates to `1`. The result: the TUI header shows `Pass 1/N`
throughout every run, regardless of which retry attempt is actually in progress.

Additionally, the output routing logic (terminal echo vs. log-file write vs. TUI
event forward) is duplicated six times in `lib/common.sh` — once each for `log()`,
`warn()`, `error()`, `success()`, `mode_info()`, and `header()`.

This milestone introduces `lib/output.sh` — the **Output Bus** foundation — which
provides:
1. A single context store (`_OUT_CTX`) as the truth for all run-state that affects display
2. A unified routing function (`_out_emit`) that eliminates the six-way duplication
3. Fixes for the `PIPELINE_ATTEMPT` ghost variable at all four attempt-counter sites

This is the foundation that M100 (stage order), M101 (ANSI migration), and M102
(TUI-aware finalize) build on.

## Design

### §1 — `lib/output.sh`: Context Store and Emit Core

New file. All content is sourced by `lib/common.sh` immediately before the existing
logging functions are defined.

**Associative array:** `declare -gA _OUT_CTX` — holds all run-state that affects
user-facing display. Keys and their sources:

| Key | Source | Example value |
|-----|--------|---------------|
| `mode` | `tekhton.sh` startup | `task`, `milestone`, `complete`, `fix-nb`, `fix-drift`, `human` |
| `attempt` | Each attempt loop (§4) | `2` |
| `max_attempts` | `tekhton.sh` startup | `5` |
| `task` | `tekhton.sh` startup | `"Add OAuth2 login"` |
| `milestone` | Milestone loop | `"99"` |
| `milestone_title` | Milestone loop | `"Output Bus Core"` |
| `stage_order` | M100 (placeholder for now) | `"scout coder security review test_verify"` |
| `cli_flags` | `tekhton.sh` startup | `"--auto-advance --skip-security"` |
| `current_stage` | Stage transitions | `"coder"` |
| `current_model` | Stage transitions | `"claude-opus-4-7"` |
| `action_items` | M102 (placeholder for now) | `""` (JSON array built in M102) |

**`out_init`** — called once at `tekhton.sh` startup after `output.sh` is sourced.
Sets safe defaults for all keys so that any call to `out_ctx KEY` before
`out_set_context` has been called returns an empty string rather than unbound-variable
errors.

**`out_set_context KEY VALUE`** — store a key in `_OUT_CTX`. Always succeeds.

**`out_ctx KEY`** — retrieve a key from `_OUT_CTX`. Prints the value (or empty string
if unset) to stdout. Used by `tui_helpers.sh` and M101/M102 formatters.

**`_out_emit LEVEL MSG...`** — the unified routing core. Implements the same branching
logic currently duplicated in `log()`, `warn()`, etc.:

```bash
_out_emit() {
    local level="$1"; shift
    local msg="$*"
    local prefix style
    case "$level" in
        info)    prefix="[tekhton]"; style="${CYAN}" ;;
        warn)    prefix="[!]";       style="${YELLOW}" ;;
        error)   prefix="[✗]";       style="${RED}" ;;
        success) prefix="[✓]";       style="${GREEN}" ;;
        header)  prefix="";          style="${BOLD}${CYAN}" ;;
        *)       prefix="[tekhton]"; style="${CYAN}" ;;
    esac

    if [[ "${_TUI_ACTIVE:-false}" != "true" ]]; then
        if [[ "$level" == "header" ]]; then
            echo -e "\n${style}══════════════════════════════════════${NC}"
            echo -e "${style}  ${msg}${NC}"
            echo -e "${style}══════════════════════════════════════${NC}\n"
        else
            echo -e "${style}${prefix}${NC} ${msg}"
        fi
    elif [[ -n "${LOG_FILE:-}" ]]; then
        if [[ "$level" == "header" ]]; then
            printf '\n=== %s ===\n' "$(_tui_strip_ansi "$msg")" >> "$LOG_FILE" 2>/dev/null || true
        else
            printf '%s %s\n' "$prefix" "$(_tui_strip_ansi "$msg")" >> "$LOG_FILE" 2>/dev/null || true
        fi
    fi
    _tui_notify "$level" "${prefix:+${prefix} }${msg}"
}
```

`_out_emit` depends on `_tui_strip_ansi` and `_tui_notify`, which are defined earlier
in `lib/common.sh`. The `source lib/output.sh` line in `common.sh` must appear
**after** those two functions are defined.

### §2 — Public Out-Functions (New Namespace)

Convenience wrappers for new code. Callers that prefer the shorter names may use
these instead of calling `_out_emit` directly.

```bash
out_log()     { _out_emit info    "$*"; }
out_warn()    { _out_emit warn    "$*"; }
out_error()   { _out_emit error   "$*"; }
out_success() { _out_emit success "$*"; }
out_header()  { _out_emit header  "$*"; }
```

### §3 — `lib/common.sh`: Collapse Duplicate Routing

The six existing output functions currently each contain 8–12 lines of identical
`_TUI_ACTIVE` branching logic. Replace each with a one-line wrapper.

**Before** (six functions, ~60 lines total, `common.sh:82–131`):
```bash
log() {
    if [[ "${_TUI_ACTIVE:-false}" != "true" ]]; then
        echo -e "${CYAN}[tekhton]${NC} $*"
    elif [[ -n "${LOG_FILE:-}" ]]; then
        printf '[tekhton] %s\n' "$(_tui_strip_ansi "$*")" >> "$LOG_FILE" 2>/dev/null || true
    fi
    _tui_notify info "$*"
}
# ... (same pattern repeated for warn, error, success, mode_info, header) ...
```

**After** (six one-line wrappers):
```bash
log()       { _out_emit info    "[tekhton] $*"; }
warn()      { _out_emit warn    "[!] $*"; }
error()     { _out_emit error   "[✗] $*"; }
success()   { _out_emit success "[✓] $*"; }
mode_info() { _out_emit info    "[~] $*"; }
header()    { _out_emit header  "$*"; }
```

Add `# shellcheck source=lib/output.sh` before the source line. The source line
must appear after `_tui_strip_ansi` and `_tui_notify` definitions (line ~80).

### §4 — Fix the `PIPELINE_ATTEMPT` Ghost Variable

`lib/tui_helpers.sh` line 107 currently reads:
```bash
local attempt="${PIPELINE_ATTEMPT:-1}"
```

`PIPELINE_ATTEMPT` is never set anywhere in the codebase. This causes the TUI to
always display `Pass 1/N`.

**Fix** (single-line change to `tui_helpers.sh:107`):
```bash
local attempt="${_OUT_CTX[attempt]:-1}"
```

### §5 — Wire `out_set_context` at All Four Attempt-Counter Sites

Each execution loop tracks its own local counter. Add `out_set_context attempt`
immediately after each increment so the TUI stays in sync.

**`lib/orchestrate.sh` — `run_complete_loop()` (line ~136):**
```bash
_ORCH_ATTEMPT=$(( _ORCH_ATTEMPT + 1 ))
out_set_context attempt "$_ORCH_ATTEMPT"
out_set_context max_attempts "${MAX_PIPELINE_ATTEMPTS:-5}"
```

**`tekhton.sh` — `_run_human_complete_loop()` (line ~2487):**
```bash
human_attempt=$((human_attempt + 1))
out_set_context attempt "$human_attempt"
```

**`tekhton.sh` — `_run_fix_nonblockers_loop()` (line ~2596):**
```bash
nb_attempt=$((nb_attempt + 1))
out_set_context attempt "$nb_attempt"
```

**`tekhton.sh` — `_run_fix_drift_loop()` (line ~2669):**
```bash
drift_attempt=$((drift_attempt + 1))
out_set_context attempt "$drift_attempt"
```

### §6 — Wire Startup Context in `tekhton.sh`

Immediately before the existing `tui_set_context` call (which is unchanged in this
milestone), add the corresponding `out_set_context` calls:

```bash
# Derive _tui_run_mode and _tui_cli_flags (existing logic, unchanged)
...

# Wire output bus context
out_set_context mode         "$_tui_run_mode"
out_set_context task         "${TASK:-}"
out_set_context cli_flags    "$_tui_cli_flags"
out_set_context max_attempts "${MAX_PIPELINE_ATTEMPTS:-5}"
out_set_context attempt      1

# Existing tui_set_context call remains unchanged here
if declare -f tui_set_context &>/dev/null; then
    tui_set_context "$_tui_run_mode" "$_tui_cli_flags" \
        "intake" "scout" "coder" "security" "review" "tester"
fi
```

For milestone context, add near the existing `_CURRENT_MILESTONE` and
`MILESTONE_TITLE` assignments:
```bash
out_set_context milestone       "${_CURRENT_MILESTONE:-}"
out_set_context milestone_title "${MILESTONE_TITLE:-}"
```

### §7 — `out_init` Initialization

`out_init` must be called once before any `out_set_context` or `_out_emit` call.
Place the call in `tekhton.sh` right after `lib/output.sh` is sourced (via
`lib/common.sh`). `out_init` sets all `_OUT_CTX` keys to empty strings, preventing
unbound-variable errors from `set -u` when any key is read before being set.

```bash
out_init() {
    declare -gA _OUT_CTX
    _OUT_CTX[mode]=""
    _OUT_CTX[attempt]="1"
    _OUT_CTX[max_attempts]="1"
    _OUT_CTX[task]=""
    _OUT_CTX[milestone]=""
    _OUT_CTX[milestone_title]=""
    _OUT_CTX[stage_order]=""
    _OUT_CTX[cli_flags]=""
    _OUT_CTX[current_stage]=""
    _OUT_CTX[current_model]=""
    _OUT_CTX[action_items]=""
}
```

## Files Modified

| File | Change |
|------|--------|
| `lib/output.sh` | **New.** `_OUT_CTX` array, `out_init`, `out_set_context`, `out_ctx`, `_out_emit`, `out_log/warn/error/success/header` (~200 lines) |
| `lib/common.sh` | `source lib/output.sh` (after `_tui_notify`); collapse six logging functions to one-line wrappers |
| `lib/tui_helpers.sh` | Line 107: change `PIPELINE_ATTEMPT` → `_OUT_CTX[attempt]` |
| `lib/orchestrate.sh` | Add `out_set_context attempt` + `out_set_context max_attempts` after `_ORCH_ATTEMPT` increment |
| `tekhton.sh` | `out_init` call at startup; `out_set_context` for mode/task/cli_flags/max_attempts/attempt/milestone at four sites |

## Acceptance Criteria

- [ ] `lib/output.sh` exists and passes `shellcheck` with zero warnings
- [ ] `declare -gA _OUT_CTX` is defined in `lib/output.sh`; `out_init` sets all
      keys to safe defaults so no `set -u` unbound-variable errors occur
- [ ] `out_set_context mode "fix-nb"` followed by `out_ctx mode` prints `fix-nb`
- [ ] `out_ctx missing_key` prints an empty string (does not error under `set -u`)
- [ ] `_out_emit info "hello"` with `_TUI_ACTIVE=false` writes
      `[tekhton] hello` (with ANSI color) to stdout
- [ ] `_out_emit warn "problem"` with `_TUI_ACTIVE=true` and `LOG_FILE` set writes
      `[!] problem` (no ANSI) to the log file and calls `_tui_notify`; produces no
      stdout output
- [ ] `log()`, `warn()`, `error()`, `success()`, `mode_info()`, `header()` produce
      byte-for-byte identical terminal output to the pre-M99 implementations
      (colors, prefixes, surrounding newlines for `header`)
- [ ] `PIPELINE_ATTEMPT` removed from `lib/tui_helpers.sh`; `grep -r PIPELINE_ATTEMPT lib/ tekhton.sh` returns zero matches
- [ ] TUI JSON status file shows correct `attempt` value (e.g., `"attempt":2`) when
      the orchestrate loop is on its second iteration — verified by inspecting
      `.tekhton/tui_status.json` mid-run or in a test
- [ ] TUI header shows correct `run_mode` for: plain task run (`task`), milestone
      run (`milestone`), `--fix nb` (`fix-nb`), `--fix drift` (`fix-drift`)
- [ ] `shellcheck` passes on all modified `.sh` files with zero new warnings
- [ ] All existing tests pass (`bash tests/run_tests.sh`)
