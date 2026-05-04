# M109 — Init Feature Wizard
<!-- milestone-meta
id: "109"
status: "done"
-->

## Overview

When `tekhton --init` creates a project config, Python-dependent features (TUI,
tree-sitter repo maps, Serena LSP) are emitted as commented-out lines in Section 5
of `pipeline.conf`. Users must know these exist, manually uncomment them, and
separately run `tekhton --setup-indexer` to install the Python venv. This gap
between "smart detection" and "feature discovery" means most users never enable
the features that make Tekhton significantly more capable.

This milestone adds a **feature wizard step** to `--init` that:

1. Detects whether Python 3.8+ is available on PATH.
2. If Python is available, asks three guided questions (TUI, repo maps, Serena)
   with each option marked **(recommended)**.
3. Writes the answers as **uncommented active config lines** in Section 5.
4. Triggers venv setup inline if any Python feature was selected.
5. If Python is not found, prints a clear message naming the enhanced features
   and pointing to `docs/getting-started/installation.md`.

The wizard runs on fresh `--init` only. On `--reinit`, the user's existing feature
choices are preserved by the existing `_merge_preserved_values()` mechanism.
Dashboard/Watchtower remains always-on by default — no question needed.

## Design

### §1 — New File: `lib/init_wizard.sh`

Single-purpose file sourced by `init.sh`. Provides one exported function and one
internal helper.

```
lib/init_wizard.sh
  ├─ _wizard_find_python3()     # Returns python3 path or returns 1
  └─ run_feature_wizard()       # Runs the interactive wizard; exports results
```

**`_wizard_find_python3()`** — Locates Python 3.8+ on PATH. Same logic as
`tools/setup_indexer.sh`'s `find_python3()` but extracted into a function that
can be called from init without invoking the full setup script. Prints the
python executable path to stdout, returns 1 if not found.

> **Why duplicate instead of sourcing `setup_indexer.sh`?** That script is a
> standalone executable: it runs `set -euo pipefail` at top level, immediately
> calls `find_python3`, and `exit 1`s on failure. Sourcing it from init would
> abort the entire init flow when Python is absent. Extracting the ~15-line
> helper is the safe, shellcheck-clean path.

Use a corrected version comparison that handles hypothetical Python 4.x:
```bash
if (( major > MIN_PYTHON_MAJOR || (major == MIN_PYTHON_MAJOR && minor >= MIN_PYTHON_MINOR) )); then
```
The existing `setup_indexer.sh` check (`-ge 3 && -ge 8`) would reject Python 4.0
(minor=0 < 8). Since we're writing a new function, use the correct comparison
from the start.

**`run_feature_wizard()`** — Entry point called from `run_smart_init()`.

Flow:

```
run_feature_wizard()
  ├─ Call _wizard_find_python3()
  │   ├─ NOT FOUND → print advisory message, export defaults, return
  │   └─ FOUND → continue
  ├─ Print: "Python 3.x found — enhanced features available."
  ├─ Ask: "Enable Rich TUI? (recommended) [Y/n]"      → _WIZARD_TUI_ENABLED
  ├─ Ask: "Enable tree-sitter repo maps? (recommended) [Y/n]" → _WIZARD_REPO_MAP_ENABLED
  ├─ Ask: "Enable Serena LSP intelligence? (recommended) [Y/n]" → _WIZARD_SERENA_ENABLED
  └─ Set: _WIZARD_NEEDS_VENV=true if any of the three are true
```

All three questions use `prompt_confirm()` from `prompts_interactive.sh` with
default `"y"`. Non-interactive mode is handled by a dedicated early-return path
in §7 — see below for details.

**Exported environment variables** (consumed by `_emit_section_features()`):

| Variable | Values | Default (no Python / non-interactive) |
|----------|--------|---------------------------------------|
| `_WIZARD_TUI_ENABLED` | `true` / `auto` / unset | unset |
| `_WIZARD_REPO_MAP_ENABLED` | `true` / unset | unset |
| `_WIZARD_SERENA_ENABLED` | `true` / unset | unset |
| `_WIZARD_NEEDS_VENV` | `true` / unset | unset |
| `_WIZARD_PYTHON_FOUND` | `true` / `false` | `false` |

When `_WIZARD_*` vars are unset, `_emit_section_features()` falls back to the
existing commented-out emission — identical behavior to today.

**Python-not-found message:**

```
  ℹ Python 3.8+ was not found on PATH.

    Enhanced features require Python and are not available right now:
      • Rich TUI — interactive live dashboard during pipeline runs
      • Tree-sitter repo maps — intelligent code context via PageRank
      • Serena LSP — language-server-powered code intelligence

    Install Python 3.8+ and run 'tekhton --setup-indexer' to enable them later.
    See: https://tekhton.dev/getting-started/installation/
```

### §2 — Integration Point in `lib/init.sh`

The wizard runs between Phase 3 (crawl) and Phase 4 (config generation).

```bash
    # Phase 3: Crawl
    ...

    # Phase 3.5: Feature wizard (M109)
    run_feature_wizard

    # Phase 4: Config generation
    ...
```

Why here:
- **After detection** — we know the user's tech stack and can give informed context.
- **Before config generation** — answers flow into `_emit_section_features()` via
  env vars. No post-hoc file editing needed.
- **Before summary** — the init report banner can reference what was enabled.

Source line added to the companion file block at the top of `init.sh`:

```bash
# shellcheck source=lib/init_wizard.sh
source "${_INIT_DIR}/init_wizard.sh"
```

### §3 — Venv Setup Trigger in `lib/init.sh`

After Phase 4 (config generation), if `_WIZARD_NEEDS_VENV=true`:

```bash
    # Phase 4.5: Python venv setup (M109)
    if [[ "${_WIZARD_NEEDS_VENV:-}" == "true" ]]; then
        log "Setting up Python environment for enhanced features..."
        mkdir -p "${conf_dir}/logs" 2>/dev/null || true
        local _setup_script="${tekhton_home}/tools/setup_indexer.sh"
        local _venv_dir="${REPO_MAP_VENV_DIR:-.claude/indexer-venv}"
        if [[ -f "$_setup_script" ]]; then
            if [[ "${VERBOSE_OUTPUT:-false}" == "true" ]]; then
                bash "$_setup_script" "$project_dir" "$_venv_dir"
            else
                # Summarized output: capture, show only success/failure
                if bash "$_setup_script" "$project_dir" "$_venv_dir" \
                        > "${conf_dir}/logs/indexer_setup.log" 2>&1; then
                    success "Python environment ready"
                else
                    warn "Python environment setup failed (see .claude/logs/indexer_setup.log)"
                    warn "You can retry later with: tekhton --setup-indexer"
                fi
            fi

            # Serena on top if selected
            if [[ "${_WIZARD_SERENA_ENABLED:-}" == "true" ]]; then
                local _serena_script="${tekhton_home}/tools/setup_serena.sh"
                if [[ -f "$_serena_script" ]]; then
                    if [[ "${VERBOSE_OUTPUT:-false}" == "true" ]]; then
                        bash "$_serena_script" "$project_dir" "${SERENA_PATH:-.claude/serena}"
                    else
                        if bash "$_serena_script" "$project_dir" "${SERENA_PATH:-.claude/serena}" \
                                >> "${conf_dir}/logs/indexer_setup.log" 2>&1; then
                            success "Serena LSP ready"
                        else
                            warn "Serena setup failed (see .claude/logs/indexer_setup.log)"
                            warn "You can retry later with: tekhton --setup-indexer --with-lsp"
                        fi
                    fi
                fi
            fi
            _INIT_FILES_WRITTEN+=(".claude/indexer-venv/|Python environment for enhanced features")
        else
            warn "setup_indexer.sh not found — run 'tekhton --setup-indexer' after init"
        fi
    fi
```

If setup fails, the user still has a working `pipeline.conf` with the features
enabled. At runtime, each feature degrades gracefully:
- TUI: falls back to standard CLI output (logs reason to `_TUI_DISABLED_REASON`)
- Repo map: logs warning, falls back to v2 context injection
- Serena: skipped with warning

The user can always retry with `tekhton --setup-indexer [--with-lsp]`.

### §4 — Config Emission Changes in `lib/init_config_sections.sh`

`_emit_section_features()` reads the wizard env vars. If set, those features are
emitted as uncommented active lines. All other features remain as they are.

```bash
_emit_section_features() {
    _emit_section_header "5" "Features" \
        "Optional features — enable as needed"

    # TUI (M109: wizard-driven)
    if [[ "${_WIZARD_TUI_ENABLED:-}" == "true" ]]; then
        echo "TUI_ENABLED=true"
    else
        echo "# TUI_ENABLED=auto"
    fi

    # Repo map (M109: wizard-driven)
    if [[ "${_WIZARD_REPO_MAP_ENABLED:-}" == "true" ]]; then
        echo "REPO_MAP_ENABLED=true"
    else
        echo "# REPO_MAP_ENABLED=false"
    fi

    # Serena (M109: wizard-driven)
    if [[ "${_WIZARD_SERENA_ENABLED:-}" == "true" ]]; then
        echo "SERENA_ENABLED=true"
    else
        echo "# SERENA_ENABLED=false"
    fi

    # Dashboard: always on (no wizard question — effectively zero cost)
    echo "DASHBOARD_ENABLED=true"

    cat << EOF
# CLEANUP_ENABLED=false
# SEED_CONTRACTS_ENABLED=false
# INTAKE_AGENT_ENABLED=true
# MILESTONE_DAG_ENABLED=true
# MILESTONE_SPLIT_ENABLED=true
# TEST_BASELINE_ENABLED=true
EOF
}
```

**Behavior changes from today's emission (both intentional):**

1. **`TUI_ENABLED` is new to Section 5.** Today's `_emit_section_features()` has
   no TUI line at all. This milestone adds it — either as an active uncommented
   `TUI_ENABLED=true` (wizard selected) or as `# TUI_ENABLED=auto` (default).

2. **`DASHBOARD_ENABLED=true` is now uncommented.** Today it's emitted as
   `# DASHBOARD_ENABLED=true` (commented suggestion). This milestone changes it
   to an active uncommented line, reflecting the design decision that Watchtower
   is always-on by default with effectively zero cost. On `--reinit`, the
   existing `_merge_preserved_values()` key-based merge sees the key already
   present (commented or not) and preserves the user's value — so this is safe.

### §5 — Banner Update in `lib/init_report_banner.sh`

The "What Tekhton learned" section of the init summary should mention Python
feature status. Add to `_init_collect_attention()`:

- If `_WIZARD_PYTHON_FOUND=true` and features were enabled:
  `"✓ Enhanced features enabled: TUI, repo maps[, Serena]"`
- If `_WIZARD_PYTHON_FOUND=false`:
  `"ℹ Install Python 3.8+ to enable enhanced features (TUI, repo maps, Serena)"`

### §6 — Reinit Behavior

No changes to `_preserve_user_config()` or `_merge_preserved_values()` are needed.

On `--reinit`:
1. `run_feature_wizard()` checks for `reinit_mode` and returns early (no-op).
   The wizard only runs on fresh init.
2. Existing `TUI_ENABLED=true`, `REPO_MAP_ENABLED=true`, etc. are preserved by
   the key-based merge already in place.
3. If the user wants to re-run the wizard, they can do a full `--init` on a fresh
   project or manually edit their config.

Implementation: `run_feature_wizard()` accepts an optional `$1` argument for
reinit mode. If `"reinit"`, it returns immediately.

```bash
run_feature_wizard() {
    local reinit_mode="${1:-}"
    if [[ "$reinit_mode" == "reinit" ]]; then
        return 0
    fi
    ...
}
```

The call site in `init.sh` passes `$reinit_mode`:

```bash
run_feature_wizard "${reinit_mode:-}"
```

**Note on empty-string safety:** When `reinit_mode` is unset, the expansion
`"${reinit_mode:-}"` passes `""` (empty string) to the function. The check
`[[ "$reinit_mode" == "reinit" ]]` correctly fails on empty string — the wizard
proceeds normally. Do not change this to a `-n` null check.

### §7 — Non-Interactive Fallback

When `TEKHTON_NON_INTERACTIVE=true` or `_can_prompt()` returns false,
`prompt_confirm()` uses its default. The wizard uses default `"y"` for all three
questions, so non-interactive mode with Python present enables all features.

This is the correct behavior: if a CI system runs `tekhton --init` and Python is
available, it gets the recommended features. If no Python, the wizard skips
gracefully and emits commented-out defaults.

**Exception:** Non-interactive mode should NOT trigger venv setup (it could fail
in constrained CI environments and block the pipeline). The wizard sets
`_WIZARD_NEEDS_VENV=true` only when interactive prompting actually occurred.
Non-interactive paths set the config values but skip venv setup — the user (or CI
script) can run `tekhton --setup-indexer` separately.

**Critical:** The non-interactive path must still check for Python before setting
feature flags. Without this guard, a CI system without Python would get
`REPO_MAP_ENABLED=true` and `SERENA_ENABLED=true` in its config, causing noisy
warnings on every pipeline run.

Also note: TUI uses `"auto"` rather than `"true"` in non-interactive mode.
Setting `true` without a venv forces the TUI on and causes an immediate fallback
with a warning log on every run. `auto` lets the TUI self-detect the venv at
runtime and "just work" once the user runs `--setup-indexer`.

```bash
if [[ "${TEKHTON_NON_INTERACTIVE:-}" == "true" ]] || ! _can_prompt; then
    # Non-interactive: check Python, enable features in config, skip venv setup
    if _wizard_find_python3 >/dev/null 2>&1; then
        _WIZARD_TUI_ENABLED="auto"      # auto-detect venv at runtime
        _WIZARD_REPO_MAP_ENABLED="true"
        _WIZARD_SERENA_ENABLED="true"
        _WIZARD_PYTHON_FOUND="true"
    else
        _WIZARD_PYTHON_FOUND="false"
    fi
    # Deliberately do NOT set _WIZARD_NEEDS_VENV
    return 0
fi
```

### §8 — Test Coverage

Add `tests/test_init_wizard.sh` with:

1. **`test_wizard_python_not_found`** — Mock `_wizard_find_python3` to fail.
   Verify wizard exports `_WIZARD_PYTHON_FOUND=false` and no `_WIZARD_NEEDS_VENV`.
   Verify advisory message is printed to stderr.

2. **`test_wizard_all_yes`** — Mock `_wizard_find_python3` to succeed, mock
   `prompt_confirm` to return 0 (yes). Verify all three `_WIZARD_*_ENABLED=true`
   and `_WIZARD_NEEDS_VENV=true`.

3. **`test_wizard_all_no`** — Mock `prompt_confirm` to return 1 (no). Verify
   all three `_WIZARD_*_ENABLED` are unset and `_WIZARD_NEEDS_VENV` is unset.

4. **`test_wizard_mixed`** — TUI yes, repo map yes, Serena no. Verify
   `_WIZARD_NEEDS_VENV=true` (TUI needs venv).

5. **`test_wizard_reinit_skipped`** — Call `run_feature_wizard "reinit"`. Verify
   all `_WIZARD_*` vars remain unset. Wizard is a no-op.

6. **`test_wizard_non_interactive`** — Set `TEKHTON_NON_INTERACTIVE=true`, mock
   `_wizard_find_python3` to succeed. Verify `_WIZARD_TUI_ENABLED=auto` (not
   `true`), `_WIZARD_REPO_MAP_ENABLED=true`, `_WIZARD_SERENA_ENABLED=true`,
   `_WIZARD_PYTHON_FOUND=true`, and `_WIZARD_NEEDS_VENV` unset.

7. **`test_wizard_non_interactive_no_python`** — Set
   `TEKHTON_NON_INTERACTIVE=true`, mock `_wizard_find_python3` to fail. Verify
   `_WIZARD_PYTHON_FOUND=false` and all `_WIZARD_*_ENABLED` vars remain unset.
   Config should emit commented-out defaults (same as no-Python interactive).

8. **`test_emit_section_features_with_wizard`** — Set `_WIZARD_TUI_ENABLED=true`
   and `_WIZARD_REPO_MAP_ENABLED=true`. Capture `_emit_section_features` output.
   Verify `TUI_ENABLED=true` and `REPO_MAP_ENABLED=true` are uncommented active
   lines. Verify `SERENA_ENABLED` remains commented. Verify
   `DASHBOARD_ENABLED=true` is always uncommented.

9. **`test_emit_section_features_without_wizard`** — All `_WIZARD_*` unset.
   Verify Section 5 looks like today's output (all features commented except
   Dashboard).

## Files Changed

| File | Change |
|------|--------|
| `lib/init_wizard.sh` | **New** — wizard function + Python detection |
| `lib/init.sh` | Source wizard, call between Phase 3–4, trigger venv after Phase 4 |
| `lib/init_config_sections.sh` | `_emit_section_features()` adds `TUI_ENABLED` (new), reads wizard env vars, uncomments `DASHBOARD_ENABLED` |
| `lib/init_report_banner.sh` | Show feature status in init summary |
| `tests/test_init_wizard.sh` | **New** — wizard + emission tests |
| `CLAUDE.md` | Add `lib/init_wizard.sh` to repo layout listing |
| `tests/run_tests.sh` | Add `test_init_wizard.sh` to test discovery (if explicit list) |

## Acceptance Criteria

- [ ] `tekhton --init` on a system with Python 3.8+ presents three feature
      questions, each marked "(recommended)", defaulting to Yes.
- [ ] Answering Yes to any Python feature triggers inline venv setup with
      summarized output (full output when `VERBOSE_OUTPUT=true`).
- [ ] `pipeline.conf` Section 5 contains uncommented `TUI_ENABLED=true`,
      `REPO_MAP_ENABLED=true`, and/or `SERENA_ENABLED=true` matching the user's
      answers.
- [ ] `DASHBOARD_ENABLED=true` is always emitted as an active uncommented line.
- [ ] `tekhton --init` on a system without Python prints an advisory message
      naming the three features and referencing `docs/getting-started/installation.md`,
      then proceeds normally with all features commented out.
- [ ] `tekhton --reinit` skips the wizard entirely; existing feature config
      values are preserved.
- [ ] Non-interactive mode (`TEKHTON_NON_INTERACTIVE=true`) with Python available
      enables features in config (TUI as `auto`, repo map + Serena as `true`)
      but does not trigger venv setup.
- [ ] Non-interactive mode without Python available leaves all features commented
      out (identical to interactive no-Python path).
- [ ] Venv setup failure does not block init — config is written, banner shows
      retry instructions, features degrade gracefully at runtime.
- [ ] All tests in `tests/test_init_wizard.sh` pass.
- [ ] `shellcheck lib/init_wizard.sh` passes with zero warnings.
- [ ] `CLAUDE.md` repo layout includes `lib/init_wizard.sh`.
- [ ] `tests/run_tests.sh` discovers and runs `test_init_wizard.sh`.
