# M101 — Eliminate Direct ANSI Output
<!-- milestone-meta
id: "101"
status: "done"
-->

## Overview

After M99 unified the routing logic for `log()`/`warn()` etc., 91 direct
`echo -e ... ${BOLD} / ${RED} / ${GREEN} / ${YELLOW} / ${CYAN}` calls remain
scattered across 10 library files. These calls bypass the output bus entirely:
they always write to stdout whether or not the TUI is active, they cannot be
routed to the log file, and they produce ANSI escape sequences that corrupt the
TUI's alternate screen buffer.

This milestone introduces `lib/output_format.sh` — a library of structured
display formatters — and migrates all 91 direct ANSI calls to use these
formatters. On completion, a grep-based lint check enforces that no new direct
ANSI calls are introduced.

**Affected files (10):**
`lib/finalize_display.sh`, `lib/finalize.sh`, `lib/clarify.sh`,
`lib/init_report_banner.sh`, `lib/report.sh`, `lib/milestone_progress_helpers.sh`,
`lib/diagnose_output.sh`, `lib/init_helpers.sh`, `lib/artifact_handler.sh`,
`lib/diagnose.sh`

## Design

### §1 — `lib/output_format.sh`: Public API

New file, sourced by `lib/common.sh` after `lib/output.sh`. All functions
respect `NO_COLOR` (defined in `common.sh`) and route through `_out_emit` so
that TUI-mode callers get event-feed entries instead of raw stdout.

---

**`out_banner TITLE [KEY VALUE ...]`**

Renders a boxed header with an optional key-value table beneath it.
In CLI mode: ANSI box with `═` borders. In TUI mode: emits title as a
`header` event and each key-value pair as an `info` event; no box drawing.

```bash
# Usage:
out_banner "Pipeline Complete" \
    "Task"    "Add OAuth2 login" \
    "Verdict" "SUCCESS" \
    "Time"    "4m12s"
```

CLI output:
```
══════════════════════════════════════
  Pipeline Complete
  Task:     Add OAuth2 login
  Verdict:  SUCCESS
  Time:     4m12s
══════════════════════════════════════
```

---

**`out_section TITLE`**

Prints a dim separator line with a centered title. Used to divide major
sections within a report.

```bash
out_section "Action Items"
```

CLI output: `──── Action Items ────────────────────`

---

**`out_kv LABEL VALUE [SEVERITY]`**

Prints a single key-value line. SEVERITY controls color:
- `normal` (default): white value
- `warn`: yellow value
- `error`: red value + `[CRITICAL]` suffix

```bash
out_kv "Open bugs"      "3"  warn
out_kv "Test failures"  "1"  error
out_kv "Drift items"    "2"
```

---

**`out_hr [LABEL]`**

Prints a horizontal rule (full terminal width). Optional LABEL is printed
inline, dim. Used between sections in reports.

---

**`out_progress LABEL CURRENT MAX`**

Prints a progress bar with counts. Used by `lib/milestone_progress_helpers.sh`.

```bash
out_progress "Milestones" 72 103
```

CLI output: `Milestones  [████████████░░░░░]  72/103`

---

**`out_action_item MSG SEVERITY`**

Prints a single action item line to terminal (CLI mode). In TUI mode, does
NOT print to stdout; instead, appends to `_OUT_CTX[action_items]` as a
JSON fragment for later use by M102's hold screen.

SEVERITY: `normal` (cyan ℹ), `warning` (yellow ⚠), `critical` (red ✗).

```bash
out_action_item "Review ARCHITECTURE_LOG.md — 3 open drift items" warning
out_action_item "Fix 2 security findings before next deploy" critical
```

`_OUT_CTX[action_items]` accumulates as a JSON array of objects:
```json
[{"msg":"Review ARCHITECTURE_LOG.md — 3 open drift items","severity":"warning"},
 {"msg":"Fix 2 security findings before next deploy","severity":"critical"}]
```

This key is read by M102's `tui_helpers.sh` change to populate `action_items`
in the JSON status file.

### §2 — `NO_COLOR` Handling

All formatters check `${NO_COLOR:-}` at call time (not at source time), since
`NO_COLOR` may be set after `common.sh` is sourced:

```bash
_out_color() {
    # Returns the color code or empty string if NO_COLOR is set
    local code="$1"
    [[ -n "${NO_COLOR:-}" ]] && echo "" || echo "$code"
}
```

All `echo -e "${BOLD}..."` patterns in the formatters use `$(_out_color "$BOLD")`
so that `NO_COLOR=1` produces clean plaintext with no escape sequences.

### §3 — Migration Strategy

Migrate one file at a time. After each file: run `shellcheck` on it, run
`bash tests/run_tests.sh`, and visually verify CLI output is unchanged.
**Do not batch multiple files into one commit.**

**Migration order** (simplest first, most complex last):

1. `lib/clarify.sh` — small; few echo calls
2. `lib/artifact_handler.sh` — small; ANSI notices
3. `lib/init_helpers.sh` — init-phase progress messages
4. `lib/diagnose.sh` — diagnostic headers
5. `lib/diagnose_output.sh` — diagnosis report
6. `lib/init_report_banner.sh` — init summary banner
7. `lib/report.sh` — run report
8. `lib/milestone_progress_helpers.sh` — progress bars (uses new `out_progress`)
9. `lib/finalize.sh` — completion gate echoes
10. `lib/finalize_display.sh` — action items (uses new `out_action_item`; most complex)

### §4 — `lib/finalize_display.sh` Migration Detail

This is the most complex migration. The current file builds an `action_items=()`
bash array and prints each item with severity-colored `echo -e`. The refactored
version calls `out_action_item MSG SEVERITY` instead. The severity mapping
(currently done by `_severity_for_count()`) is preserved as-is; only the output
call changes.

**Before (pattern, repeated ~8 times):**
```bash
echo -e "${RED}✗ ${count} test failure(s) detected — fix before shipping${NC} [CRITICAL]"
```

**After:**
```bash
out_action_item "${count} test failure(s) detected — fix before shipping" critical
```

The `out_action_item` function handles the prefix symbol (✗/⚠/ℹ) and severity
color internally, so callers pass only the message text and severity string.

### §5 — Lint Enforcement

Add to `tests/test_output_lint.sh` (created in this milestone, not M103):

```bash
# Fail if any direct ANSI echo calls exist outside the output module
count=$(grep -rn \
    'echo -e.*\${\(BOLD\|RED\|GREEN\|YELLOW\|CYAN\|NC\)}' \
    lib/ stages/ \
    --include="*.sh" \
    | grep -v 'lib/common\.sh\|lib/output\.sh\|lib/output_format\.sh' \
    | wc -l)

if [[ "$count" -gt 0 ]]; then
    echo "FAIL: ${count} direct ANSI echo calls found outside output module:"
    grep -rn \
        'echo -e.*\${\(BOLD\|RED\|GREEN\|YELLOW\|CYAN\|NC\)}' \
        lib/ stages/ \
        --include="*.sh" \
        | grep -v 'lib/common\.sh\|lib/output\.sh\|lib/output_format\.sh'
    exit 1
fi
echo "PASS: No direct ANSI echo calls outside output module"
```

This test is run as part of M103's full test suite but exists as a standalone
file that can be run independently.

## Files Modified

| File | Change |
|------|--------|
| `lib/output_format.sh` | **New.** `out_banner`, `out_section`, `out_kv`, `out_hr`, `out_progress`, `out_action_item`, `_out_color` (~250 lines) |
| `lib/common.sh` | `source lib/output_format.sh` after `source lib/output.sh` |
| `lib/clarify.sh` | Replace direct ANSI echoes with `out_section`/`out_kv` |
| `lib/artifact_handler.sh` | Replace direct ANSI echoes with `out_warn`/`out_section` |
| `lib/init_helpers.sh` | Replace direct ANSI echoes with `out_log`/`out_section` |
| `lib/diagnose.sh` | Replace direct ANSI echoes with `out_header`/`out_section` |
| `lib/diagnose_output.sh` | Replace direct ANSI echoes with `out_banner`/`out_section`/`out_kv` |
| `lib/init_report_banner.sh` | Replace direct ANSI echoes with `out_banner` |
| `lib/report.sh` | Replace direct ANSI echoes with `out_banner`/`out_kv` |
| `lib/milestone_progress_helpers.sh` | Replace direct ANSI echoes with `out_progress`/`out_section` |
| `lib/finalize.sh` | Replace direct ANSI echoes with `out_log`/`out_success` |
| `lib/finalize_display.sh` | Replace `echo -e` action-item calls with `out_action_item`; preserve severity logic |
| `tests/test_output_lint.sh` | **New.** Grep-based lint check (see §5) |

## Acceptance Criteria

- [ ] `lib/output_format.sh` exists and passes `shellcheck` with zero warnings
- [ ] `out_banner "Test" "Key" "Value"` produces a boxed header with key-value row
      in CLI mode; in TUI mode produces a `header` event followed by an `info` event
      (no stdout box-drawing chars that would corrupt the alternate screen)
- [ ] `out_action_item "fix this" critical` in CLI mode prints `✗ fix this [CRITICAL]`
      in red to stdout; in TUI mode produces no stdout output and appends a JSON
      object to `_OUT_CTX[action_items]`
- [ ] `NO_COLOR=1` before sourcing: all formatter functions produce no ANSI escape
      sequences — verified by piping output through `cat -v` and confirming no `^[`
- [ ] `tests/test_output_lint.sh` passes: zero direct `echo -e` ANSI calls in
      `lib/` and `stages/` outside `common.sh`, `output.sh`, `output_format.sh`
- [ ] Each of the 10 migrated files passes `shellcheck` individually after its migration
- [ ] CLI output of `--diagnose`, `--init`, `--progress`, and `tekhton.sh` finalize
      banner is visually unchanged from pre-M101 (same text, same colors) — spot-
      checked manually
- [ ] `bash tests/run_tests.sh` passes after all 10 files are migrated
- [ ] `shellcheck` passes on all new and modified `.sh` files with zero warnings
