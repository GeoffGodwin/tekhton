# M102 — TUI-Aware Finalize + Completion Flow
<!-- milestone-meta
id: "102"
status: "done"
-->

## Overview

When the TUI sidecar is active, the finalize banner (printed by `lib/finalize.sh`
and `lib/finalize_display.sh`) currently races against the TUI's alternate screen
buffer. The TUI owns the screen via `rich.Live`; the finalize code writes to stdout
via the normal terminal scroll. Whichever wins the race determines what the user
sees — typically a garbled mix of TUI border fragments and banner text.

Additionally, the `action_items` field in the TUI JSON status has been hardcoded
as `[]` since M97. The M98 hold-on-complete screen (in `tools/tui_hold.py`) already
has a placeholder to display action items, but nothing populates them.

After M101, `out_action_item` calls in `lib/finalize_display.sh` accumulate action
items in `_OUT_CTX[action_items]`. This milestone wires those items into the TUI
JSON and ensures the completion sequence is race-free:

1. `lib/finalize_display.sh` calls `out_action_item` (M101) → items in `_OUT_CTX`
2. `out_complete VERDICT` writes the final JSON (with action items) and signals the sidecar
3. Sidecar exits `Live` → prints hold screen (event log + action items + Enter prompt)
4. User presses Enter → sidecar exits → `tui_stop` returns → finalize banner prints in normal scroll

## Design

### §1 — `out_complete VERDICT` in `lib/output.sh`

New public function added to `lib/output.sh`. Replaces the direct `tui_complete`
call at the end of `finalize_run`.

```bash
out_complete() {
    local verdict="${1:-}"
    # Update context
    _OUT_CTX[mode]="${_OUT_CTX[mode]:-task}"  # preserve existing mode
    # Delegate to tui_complete if TUI is active
    if declare -f tui_complete &>/dev/null; then
        tui_complete "$verdict"
    fi
}
```

`tui_complete` (in `lib/tui.sh`) already handles the full hold-and-wait sequence
introduced in M98. `out_complete` is a thin wrapper that ensures the verdict flows
through the context store (for future M103 tests) before delegating.

### §2 — Populate `action_items` in TUI JSON

`lib/tui_helpers.sh` line 157 currently hardcodes `'"action_items":[],'`. Replace
this with a read from `_OUT_CTX[action_items]`:

**Before (`tui_helpers.sh:157`):**
```bash
printf '"action_items":[],'
```

**After:**
```bash
local action_items_json
action_items_json="${_OUT_CTX[action_items]:-[]}"
# Ensure it's valid JSON array (non-empty string defaults to empty array)
[[ "$action_items_json" == "" ]] && action_items_json="[]"
printf '"action_items":%s,' "$action_items_json"
```

`_OUT_CTX[action_items]` is built by `out_action_item` (M101) as a JSON array
string. It starts empty (`""`) and grows as items are appended:

```bash
# In lib/output_format.sh — out_action_item internal append logic:
out_action_item() {
    local msg="$1" severity="${2:-normal}"
    # CLI mode: print directly
    if [[ "${_TUI_ACTIVE:-false}" != "true" ]]; then
        local prefix style
        case "$severity" in
            critical) prefix="✗"; style="${RED}" ;;
            warning)  prefix="⚠"; style="${YELLOW}" ;;
            *)        prefix="ℹ"; style="${CYAN}" ;;
        esac
        local suffix=""
        [[ "$severity" == "critical" ]] && suffix=" [CRITICAL]"
        echo -e "${style}${prefix} ${msg}${NC}${suffix}"
        return
    fi
    # TUI mode: accumulate JSON, suppress stdout
    local escaped_msg
    escaped_msg=$(printf '%s' "$msg" | sed 's/"/\\"/g; s/\\/\\\\/g')
    local item="{\"msg\":\"${escaped_msg}\",\"severity\":\"${severity}\"}"
    local current="${_OUT_CTX[action_items]:-}"
    if [[ -z "$current" ]] || [[ "$current" == "[]" ]]; then
        _OUT_CTX[action_items]="[${item}]"
    else
        # Insert before closing bracket
        _OUT_CTX[action_items]="${current%]},${item}]"
    fi
}
```

**JSON element schema:**
```json
{"msg": "<human-readable text>", "severity": "<normal|warning|critical>"}
```

### §3 — `tools/tui_hold.py`: Render Action Items

`tools/tui_hold.py` already defines `_hold_on_complete()` (M98). Add action-item
rendering between the event log and the Enter prompt:

```python
# After printing event log, before the Enter prompt:
action_items = status.get("action_items") or []
if action_items:
    console.print()
    console.print("[bold]Action items:[/bold]", style="dim")
    severity_styles = {
        "critical": ("✗", "bold red"),
        "warning":  ("⚠", "yellow"),
        "normal":   ("ℹ", "cyan"),
    }
    for item in action_items:
        msg      = item.get("msg", "")
        severity = item.get("severity", "normal")
        icon, style = severity_styles.get(severity, ("ℹ", "cyan"))
        suffix = "  [CRITICAL]" if severity == "critical" else ""
        console.print(f"  [{style}]{icon} {msg}{suffix}[/{style}]")
    console.print()
```

### §4 — Guard Finalize Banner When TUI Is Active

`lib/finalize.sh` currently calls `_print_action_items` and other display functions
directly after `tui_complete`. After M101, these calls go through `out_action_item`
(TUI: suppressed to `_OUT_CTX[action_items]`). But any remaining direct stdout
writes in `lib/finalize.sh` must be guarded.

The ordering is now:
```bash
# lib/finalize.sh — finalize_run() end sequence
_print_action_items       # uses out_action_item → accumulates in _OUT_CTX (TUI mode)
                          # or prints directly (CLI mode)
out_complete "$verdict"   # signals TUI; TUI prints hold screen + action items; waits for Enter
                          # (CLI mode: no-op on TUI side, just returns)
_print_finalize_banner    # prints in normal scroll — safe in both modes because:
                          # TUI mode: alternate screen already restored by tui_complete
                          # CLI mode: prints to stdout as before
```

Verify that `_print_action_items` is called **before** `out_complete` so that items
are in `_OUT_CTX[action_items]` when the sidecar reads the final JSON.

### §5 — CLI-Mode Regression Contract

When `_TUI_ACTIVE=false`:
- `out_action_item` prints directly to stdout with ANSI color (unchanged from M101)
- `out_complete` is a no-op on the TUI path (no sidecar running)
- `_print_finalize_banner` prints normally
- Overall behavior: byte-for-byte identical to pre-M102 CLI output

This must be verified explicitly in the acceptance criteria (no regression path
can be assumed correct without a test).

## Files Modified

| File | Change |
|------|--------|
| `lib/output.sh` | Add `out_complete VERDICT` function |
| `lib/tui_helpers.sh` | Line 157: read `action_items` from `_OUT_CTX[action_items]` instead of hardcoded `[]` |
| `lib/output_format.sh` | `out_action_item` TUI branch: accumulate JSON into `_OUT_CTX[action_items]` (M101 adds the function; M102 adds the TUI accumulation branch) |
| `lib/finalize.sh` | Call `out_complete "$verdict"` in place of direct `tui_complete`; ensure `_print_action_items` is called before `out_complete` |
| `tools/tui_hold.py` | Render `action_items` array with severity icons and colors |

## Acceptance Criteria

- [ ] `out_complete "SUCCESS"` exists in `lib/output.sh` and delegates to
      `tui_complete` when the function is defined
- [ ] In TUI mode: `out_action_item "fix tests" critical` appends
      `{"msg":"fix tests","severity":"critical"}` to `_OUT_CTX[action_items]`;
      produces no stdout output
- [ ] In CLI mode: `out_action_item "fix tests" critical` prints
      `✗ fix tests [CRITICAL]` (red) to stdout; does NOT modify `_OUT_CTX`
- [ ] TUI JSON `action_items` field contains the full list of items emitted
      by `lib/finalize_display.sh` during a complete run — verified by
      inspecting `.tekhton/tui_status.json` after `out_complete` is called
- [ ] `tools/tui_hold.py` hold screen displays action items with correct
      severity icons (✗ red for critical, ⚠ yellow for warning, ℹ cyan for normal)
- [ ] No stdout output races the TUI alternate screen: when TUI is active, the
      finalize banner appears in normal terminal scroll **after** the user presses
      Enter on the hold screen (verified manually or via timeout test)
- [ ] CLI-only mode (no TUI): finalize output is byte-for-byte identical to
      pre-M102 — same action item lines, same colors, same banner text
- [ ] `grep -n 'action_items.*\[\]' lib/tui_helpers.sh` returns zero matches
      (hardcoded empty array is gone)
- [ ] `shellcheck` passes on all modified `.sh` files with zero new warnings
- [ ] All existing tests pass (`bash tests/run_tests.sh`)
