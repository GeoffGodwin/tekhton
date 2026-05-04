# M100 — Dynamic Stage Order + TUI Sync
<!-- milestone-meta
id: "100"
status: "done"
-->

## Overview

The TUI stage-pill row shows `intake ✓ scout ▶ coder ○ security ○ review ○ tester`
with the order and set of stages hardcoded in `tekhton.sh`. Three sources of stage
information now disagree:

1. **`lib/pipeline_order.sh`** — authoritative execution order; produces
   `scout coder security review test_verify` (standard) or inserts `docs` when
   `DOCS_AGENT_ENABLED=true`.
2. **`tekhton.sh` `tui_set_context` call** — hardcodes
   `"intake" "scout" "coder" "security" "review" "tester"` regardless of config.
3. **`tools/tui.py`** — has its own fallback stage list used when `stage_order` is
   absent from the JSON status file.

The result: `--skip-security`, `DOCS_AGENT_ENABLED=true`, and `PIPELINE_ORDER=test_first`
all produce TUI stage pills that don't reflect reality. The `tui.py` fallback is dead
code that could silently mask future regressions.

This milestone makes the stage-pill display dynamically accurate by building it from
`get_pipeline_order()` and storing it in `_OUT_CTX[stage_order]`.

## Design

### §1 — Stage Name Mapping

`get_pipeline_order()` returns internal stage identifiers; the TUI display uses
human-readable labels. A mapping function normalises them:

| Internal name | Display label | Notes |
|---------------|---------------|-------|
| `scout` | `scout` | unchanged |
| `coder` | `coder` | unchanged |
| `security` | `security` | unchanged |
| `review` | `review` | unchanged |
| `test_verify` | `tester` | standard tester pass |
| `test_write` | `tester-write` | TDD: write-failing-tests pass |
| `docs` | `docs` | optional docs agent |

`intake` is prepended separately when `INTAKE_AGENT_ENABLED=true` (default). It
is not returned by `get_pipeline_order()` because it runs before the main pipeline
loop, but it is a visible stage in the TUI.

### §2 — New Helper: `get_display_stage_order` in `lib/pipeline_order.sh`

Add a new function to `lib/pipeline_order.sh` that composes the full TUI-visible
stage list:

```bash
# get_display_stage_order — Echo the space-separated display stage labels for the TUI.
# Prepends "intake" when INTAKE_AGENT_ENABLED=true (default).
# Maps internal names (test_verify, test_write) to display labels.
# Output: space-separated string, e.g. "intake scout coder docs security review tester"
get_display_stage_order() {
    local stages display=""

    # Prepend intake if enabled (runs before the main pipeline)
    if [[ "${INTAKE_AGENT_ENABLED:-true}" == "true" ]]; then
        display="intake"
    fi

    # Get the execution-order stages and map to display names
    stages=$(get_pipeline_order)
    local s
    for s in $stages; do
        case "$s" in
            test_verify) display="${display:+$display }tester" ;;
            test_write)  display="${display:+$display }tester-write" ;;
            *)           display="${display:+$display }$s" ;;
        esac
    done

    echo "$display"
}
```

### §3 — Replace Hardcoded `tui_set_context` Call in `tekhton.sh`

**Before:**
```bash
if declare -f tui_set_context &>/dev/null; then
    tui_set_context "$_tui_run_mode" "$_tui_cli_flags" \
        "intake" "scout" "coder" "security" "review" "tester"
fi
```

**After:**
```bash
# Build dynamic stage display order from pipeline config
_display_order=$(get_display_stage_order)
out_set_context stage_order "$_display_order"

if declare -f tui_set_context &>/dev/null; then
    # shellcheck disable=SC2086
    IFS=' ' read -ra _stage_arr <<< "$_display_order"
    tui_set_context "$_tui_run_mode" "$_tui_cli_flags" "${_stage_arr[@]}"
fi
```

This ensures both `_OUT_CTX[stage_order]` and `_TUI_STAGE_ORDER` (used by
`tui_helpers.sh`) are populated from the same source.

### §4 — Dynamic Update on Stage Skip

When a stage is skipped at runtime (e.g., security disabled mid-run via
`SKIP_SECURITY=true`), `_OUT_CTX[stage_order]` must be refreshed. Add a call to
`out_set_context stage_order "$(get_display_stage_order)"` at the point in
`tekhton.sh` where skip decisions are applied (just before `_run_pipeline_stages`
starts iterating). This ensures that if `SKIP_SECURITY` or `DOCS_AGENT_ENABLED`
is determined at runtime rather than at startup, the TUI reflects the actual order.

Additionally, update `_TUI_STAGE_ORDER` via `tui_set_context` at the same point:
```bash
_display_order=$(get_display_stage_order)
out_set_context stage_order "$_display_order"
IFS=' ' read -ra _stage_arr <<< "$_display_order"
# tui_set_context preserves run_mode and cli_flags, updates stage_order only
if declare -f tui_set_context &>/dev/null; then
    tui_set_context "${_OUT_CTX[mode]:-task}" "${_OUT_CTX[cli_flags]:-}" "${_stage_arr[@]}"
fi
```

### §5 — Remove `tui.py` Hardcoded Fallback

`tools/tui.py` contains a fallback stage list used when `stage_order` is missing or
empty in the JSON. After M99+M100, `stage_order` is always populated before the TUI
starts. Remove the fallback entirely. If `stage_order` is empty, derive a minimal
display from `stage_num` / `stage_total` instead (e.g., `Stage N of M`) rather than
showing a hardcoded list.

Search for the fallback in `tui.py` (likely near the `_build_header_bar` or
`_build_stage_pills` function) and replace the hardcoded list with:

```python
stage_order = status.get("stage_order") or []
if not stage_order and (stage_total := status.get("stage_total", 0)):
    # Minimal fallback: numbered placeholders when stage_order not yet populated
    stage_order = [f"stage-{i+1}" for i in range(stage_total)]
```

### §6 — `tui_helpers.sh`: Read `stage_order` from `_OUT_CTX`

`_tui_stage_order_json()` already reads from `_TUI_STAGE_ORDER` array (set by
`tui_set_context`). No change needed there — §3 above ensures `_TUI_STAGE_ORDER` is
always built from `get_display_stage_order()`.

However, for the M101+ path where `tui_set_context` may be replaced by `out_set_context`
alone, add a fallback in `_tui_stage_order_json()`:

```bash
_tui_stage_order_json() {
    # Prefer _TUI_STAGE_ORDER array; fall back to _OUT_CTX[stage_order] string
    local src=("${_TUI_STAGE_ORDER[@]:-}")
    if [[ "${#src[@]}" -eq 0 ]] && [[ -n "${_OUT_CTX[stage_order]:-}" ]]; then
        IFS=' ' read -ra src <<< "${_OUT_CTX[stage_order]}"
    fi
    printf '['
    local first=1 s
    for s in "${src[@]:-}"; do
        [[ -z "$s" ]] && continue
        (( first )) && first=0 || printf ','
        printf '"%s"' "$(_tui_escape "$s")"
    done
    printf ']'
}
```

## Files Modified

| File | Change |
|------|--------|
| `lib/pipeline_order.sh` | Add `get_display_stage_order()` function |
| `tekhton.sh` | Replace hardcoded `tui_set_context` stage list with `get_display_stage_order()` output; add `out_set_context stage_order`; add runtime-skip refresh call |
| `lib/tui_helpers.sh` | `_tui_stage_order_json()`: add `_OUT_CTX[stage_order]` fallback when `_TUI_STAGE_ORDER` is empty |
| `tools/tui.py` | Remove hardcoded fallback stage list; use numbered placeholders when `stage_order` absent |

## Acceptance Criteria

- [ ] `get_display_stage_order` function exists in `lib/pipeline_order.sh` and
      passes `shellcheck`
- [ ] Standard run (no flags): TUI stage pills show
      `intake scout coder security review tester` in that order
- [ ] `INTAKE_AGENT_ENABLED=false`: pills show `scout coder security review tester`
      (no `intake`)
- [ ] `DOCS_AGENT_ENABLED=true`: pills show
      `intake scout coder docs security review tester`
- [ ] `PIPELINE_ORDER=test_first`: pills show
      `intake scout tester-write coder security review tester`
- [ ] `SKIP_SECURITY=true` (runtime skip): pills update to exclude `security`
      after the skip decision is applied — verified by inspecting `tui_status.json`
- [ ] `tools/tui.py` contains no hardcoded stage list; if `stage_order` is absent
      from JSON, the pills panel falls back gracefully (numbered placeholders or empty)
      rather than showing a stale hardcoded list
- [ ] `_tui_stage_order_json()` reads from `_OUT_CTX[stage_order]` when
      `_TUI_STAGE_ORDER` is empty — verified by unit test
- [ ] `shellcheck` passes on all modified `.sh` files with zero new warnings
- [ ] All existing tests pass (`bash tests/run_tests.sh`)
