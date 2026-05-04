# Milestone 81: Brownfield --init Narrative & Guided Next Step
<!-- milestone-meta
id: "81"
status: "done"
-->

## Overview

Developer feedback: "When I run `--init` on an existing project I get a
detection summary but no sense of *what just happened* or *what to do
next*. I end up re-reading the README to find the right follow-up
command."

Today's `emit_init_summary` in `lib/init_report.sh:18` already prints:

- Detected language / framework / commands
- Needs-attention items
- Health score
- A three-line "Next steps" block

The **data** is good. The **narrative** is missing. A new user can't
tell:

1. What did Tekhton learn about my project? (summary of crawl results)
2. What files did it write and where? (so they know what to inspect)
3. What should I do *right now*? (one recommended command, not three)

M81 is a **surgical UX polish** milestone on top of the existing
function — no new detection logic, no new state files, just a richer
post-init banner and an optional auto-prompt for the next command.

## Design Decisions

### 1. Three-part banner, replace existing summary

Rewrite `emit_init_summary` to emit three sections in order:

```
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Tekhton initialized for: my-project
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  What Tekhton learned
    ● TypeScript project (Vite + React, 47 source files)
    ● Framework: React 18 (from package.json)
    ● Build: npm run build   Test: npm test   Lint: npm run lint
    ● Health score: 72/100 (3 items need attention)

  What Tekhton wrote
    ● .claude/pipeline.conf            (primary config — edit this first)
    ● .claude/agents/coder.md          (coder role — customize for your stack)
    ● .claude/agents/reviewer.md       (reviewer role)
    ● .claude/agents/tester.md         (tester role)
    ● PROJECT_INDEX.md                 (structured project index)
    ● INIT_REPORT.md                   (full detection report)

  What's next
    ▶  tekhton --plan-from-index   (recommended — synthesizes a plan from
                                    the detected structure)
       or --draft-milestones       (for small additive work)
       or --plan                   (greenfield-style interview, from scratch)

  Run `tekhton --help` for all commands.
```

Key differences from the current output:

- **"What Tekhton learned"** is narrative — a paragraph's worth of
  detection compressed into 4 bullets.
- **"What Tekhton wrote"** is an **explicit file list**, not a link to
  `INIT_REPORT.md`. Users want to see which files to open without
  opening a separate report first.
- **"What's next"** has a **single recommended command** marked with
  `▶` and alternates below it. Current implementation offers 3
  parallel options with equal weight — paralyzing.

### 2. Recommended-command heuristic

The "What's next" recommendation is computed from the crawl data:

| Signal | Recommendation |
|--------|----------------|
| `file_count > 50` AND no `MANIFEST.cfg` | `--plan-from-index` |
| `file_count > 50` AND `MANIFEST.cfg` with pending milestones | `tekhton` (just run — picks first pending) |
| `file_count < 50` AND no `MANIFEST.cfg` | `--plan` |
| `file_count < 50` AND the project has `docs/` or `README.md` > 500 lines | `--draft-milestones "describe your next goal"` |
| No code files detected (planning docs only) | `--plan "describe your project goals"` |

Single winner with alternates listed below. No ties.

### 3. Optional auto-prompt

New config var `INIT_AUTO_PROMPT=false` (default false for safety). When
true, after the banner, print:

```
  Run tekhton --plan-from-index now? [Y/n]
```

If user hits enter or `y`, Tekhton execs the recommended command as if
it had been typed. If `n`, exits with code 0. Only enabled when
stdin is a TTY — CI runs always skip this.

Setting to false by default honors the principle of least surprise —
a first-run user who just ran `--init` shouldn't have a second agent
invocation fire on them automatically. Users who like the flow can
set `INIT_AUTO_PROMPT=true` in their shell profile or
`.claude/pipeline.conf`.

### 4. "What Tekhton wrote" file list comes from actual writes

Don't hard-code the file list — collect it as init runs. Add a
`_INIT_FILES_WRITTEN` array to `lib/init.sh` and have every file-write
helper push onto it:

```bash
_INIT_FILES_WRITTEN+=("$path|$description")
```

`emit_init_summary` reads the array and renders it. Preserves accuracy
when features are toggled off (e.g., `DASHBOARD_ENABLED=false` means no
`.claude/dashboard/` files get written — they shouldn't appear in the
list).

### 5. Health score gets a narrative line

Current output: `Health score: 72/100`. New output: `Health score:
72/100 (3 items need attention)`. Uses the existing
`attention_items` count that's already computed earlier in the
function. No new data collection — just threading the count into the
output.

### 6. Color + unicode, graceful fallback

Use `━` for the divider (U+2501) and `●` for bullets (U+25CF). These
render in every modern terminal. If `NO_COLOR=1`, fall back to `=` and
`*`. If `LANG` doesn't include UTF-8, same fallback. Matches the
project's existing color-fallback patterns in `lib/common.sh`.

### 7. Preserve backwards compat for the non-summary code path

`emit_init_report_file` (the `INIT_REPORT.md` writer) is NOT touched.
That function stays as-is. The banner is purely about the terminal
output from `emit_init_summary`. Users scripting against
`INIT_REPORT.md` for CI see zero change.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Rewritten functions | 1 | `emit_init_summary` in `lib/init_report.sh` |
| New helpers | 2 | `_init_pick_recommendation`, `_init_render_files_written` |
| New state | 1 | `_INIT_FILES_WRITTEN` array populated during init |
| New config vars | 1 | `INIT_AUTO_PROMPT` |
| New template vars | 1 | Mirrored |
| Tests | 1 | Fixture-driven recommendation test |
| Files modified | 3 | `lib/init_report.sh`, `lib/init.sh`, `lib/config_defaults.sh` |

## Implementation Plan

### Step 1 — Config scaffolding

Edit `lib/config_defaults.sh` — add `INIT_AUTO_PROMPT=false`. Edit
`lib/prompts.sh` — register as template var (even though no prompt
uses it yet; keeps the registry complete). Run
`bash tests/run_tests.sh`. Must pass unchanged.

### Step 2 — File-written tracking

Edit `lib/init.sh` — at the top declare `_INIT_FILES_WRITTEN=()` as a
global. At each existing file-write site, append an entry:

```bash
_INIT_FILES_WRITTEN+=("$pipeline_conf_path|primary config — edit this first")
_INIT_FILES_WRITTEN+=("$coder_role_path|coder role — customize for your stack")
...
```

Audit every file-write in `lib/init.sh` + `lib/init_helpers.sh` +
`lib/init_config.sh` and add the push. Small mechanical change.

### Step 3 — Recommendation helper

Add `_init_pick_recommendation` to `lib/init_report.sh`:

```bash
# Args: $1=file_count, $2=has_manifest(true/false), $3=has_pending_milestones(true/false)
# Emits: CMD|DESCRIPTION|ALT1|ALT2
_init_pick_recommendation() {
    local file_count="$1"
    local has_manifest="$2"
    local has_pending="$3"

    if [[ "$has_pending" == "true" ]]; then
        echo "tekhton|run next pending milestone|--draft-milestones|--plan"
    elif [[ "$file_count" -gt 50 ]]; then
        echo "tekhton --plan-from-index|synthesize plan from detected structure|--draft-milestones|--plan"
    elif [[ "$file_count" -gt 0 ]]; then
        echo "tekhton --plan \"goal\"|interview-style plan|--draft-milestones|"
    else
        echo "tekhton --plan \"goal\"|interview-style plan (greenfield)||"
    fi
}
```

Pure function, trivially unit-testable.

### Step 4 — Rewrite the banner

Replace `emit_init_summary`'s body (lines ~18–169) with:

1. Header divider + project name.
2. "What Tekhton learned" block — reuse existing detection outputs.
3. "What Tekhton wrote" block — iterate `_INIT_FILES_WRITTEN[@]`.
4. "What's next" block — call `_init_pick_recommendation`.
5. Auto-prompt block — gated on `INIT_AUTO_PROMPT=true` AND TTY check.

Keep `_emit_summary_command`, `_is_watchtower_enabled` helpers as-is.
Keep `emit_init_report_file` untouched.

### Step 5 — TTY + NO_COLOR guards

Wrap the auto-prompt in:

```bash
if [[ "${INIT_AUTO_PROMPT:-false}" == "true" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
    read -r -p "  Run ${rec_cmd} now? [Y/n] " _reply
    case "${_reply:-Y}" in
        y|Y|yes|Yes|YES|"") exec $rec_cmd ;;
        *) : ;;
    esac
fi
```

The `exec` replaces the current shell — no nested tekhton invocation.
Honor `NO_COLOR=1` for the divider/bullet fallback.

### Step 6 — Tests

Create `tests/test_init_recommendation.sh`:

- `file_count=0, has_manifest=false, has_pending=false` → `tekhton --plan "goal"`
- `file_count=10, has_manifest=false, has_pending=false` → `tekhton --plan "goal"`
- `file_count=100, has_manifest=false, has_pending=false` → `tekhton --plan-from-index`
- `file_count=100, has_manifest=true, has_pending=true` → `tekhton` (run next milestone)

Short test — just exercises the pure helper. Add to `tests/run_tests.sh`.

Also add a banner fixture test: write a fake `_INIT_FILES_WRITTEN`
array, call `emit_init_summary` with stub args, capture stdout, assert
the output contains "What Tekhton learned", "What Tekhton wrote", and
"What's next" headers. Low-value but catches regressions.

### Step 7 — Shellcheck + tests + version bump

```bash
shellcheck lib/init.sh lib/init_report.sh lib/init_helpers.sh lib/config_defaults.sh
bash tests/run_tests.sh
```

Edit `tekhton.sh` — `TEKHTON_VERSION="3.81.0"`.
Edit manifest — M81 row with `depends_on=m80`, group `devx`.

Dependency: depends on M80 so the recommendation can point at
`--draft-milestones` (introduced in M80). If M80 slips, M81's
recommendation logic falls back to `--plan`.

## Files Touched

### Added
- `tests/test_init_recommendation.sh`
- `.claude/milestones/m81-brownfield-init-narrative.md` — this file

### Modified
- `lib/init_report.sh` — rewrite `emit_init_summary`
- `lib/init.sh` — add `_INIT_FILES_WRITTEN` tracking
- `lib/init_helpers.sh` — push entries onto the array
- `lib/init_config.sh` — push entries onto the array
- `lib/config_defaults.sh` — `INIT_AUTO_PROMPT=false`
- `lib/prompts.sh` — register template var
- `tests/run_tests.sh` — register `test_init_recommendation.sh`
- `tekhton.sh` — `TEKHTON_VERSION` to `3.81.0`
- `.claude/milestones/MANIFEST.cfg` — M81 row

## Acceptance Criteria

- [ ] `emit_init_summary` prints three labeled sections: "What Tekhton
      learned", "What Tekhton wrote", "What's next"
- [ ] "What Tekhton wrote" lists actual files written during init (not
      a hard-coded list), sourced from `_INIT_FILES_WRITTEN`
- [ ] Each file-write site in `lib/init.sh`, `lib/init_helpers.sh`, and
      `lib/init_config.sh` appends to `_INIT_FILES_WRITTEN`
- [ ] "What's next" emits exactly one recommended command, highlighted
      with `▶` or equivalent marker
- [ ] Recommendation heuristic: file_count > 50 without manifest →
      `--plan-from-index`; file_count > 50 with pending milestones →
      `tekhton`; file_count < 50 → `--plan`; zero files → `--plan`
- [ ] `INIT_AUTO_PROMPT=false` by default
- [ ] When `INIT_AUTO_PROMPT=true` AND stdin is a TTY, banner ends with
      a yes/no prompt to run the recommended command
- [ ] When `INIT_AUTO_PROMPT=true` AND stdin is NOT a TTY, no prompt is
      shown (CI-safe)
- [ ] `NO_COLOR=1` falls back to ASCII dividers and bullets
- [ ] `_init_pick_recommendation` is a pure function passing all four
      scenarios in `tests/test_init_recommendation.sh`
- [ ] `emit_init_report_file` is untouched — backwards compat preserved
- [ ] `bash tests/run_tests.sh` passes with zero failures
- [ ] `shellcheck` on modified files reports zero warnings
- [ ] `tekhton.sh` `TEKHTON_VERSION` is `3.81.0`
- [ ] `.claude/milestones/MANIFEST.cfg` contains the M81 row
      (`depends_on=m80`, group `devx`)

## Watch For

- **`exec` in the auto-prompt path.** Using `exec` replaces the init
  process with the recommended command. That means the init process's
  trap handlers and cleanup fire BEFORE the exec, not after. If the
  init process owns temp files that need cleanup, make sure traps have
  already run. Test carefully before enabling.
- **Don't silently run the recommended command.** The default is
  `INIT_AUTO_PROMPT=false` for a reason — an unexpected auto-fire on
  a first-run experience would break the principle of least surprise.
  Even with the env var set, the TTY check must gate the prompt to
  avoid CI mishaps.
- **Array backcompat in bash.** `_INIT_FILES_WRITTEN+=(...)` works in
  bash 4+, which is already a hard dep. Double-check the array is
  declared at global scope (not inside a function with `local`), or
  pushes from subshells will vanish.
- **File list must be concise.** If init writes 20+ files (dashboard
  templates, config subdirs, etc.), the "What Tekhton wrote" section
  bloats the banner. Truncate to the top 8 entries with a "...plus 12
  more" footer. Pick the 8 by categorical importance: pipeline.conf,
  agent roles, PROJECT_INDEX.md, INIT_REPORT.md first.
- **Don't duplicate what INIT_REPORT.md says.** The banner is a
  high-signal summary. Details live in `INIT_REPORT.md`. Link to it
  with one line: `Full report: INIT_REPORT.md`. Don't paste the whole
  report into the banner.
- **Test the recommendation with empty detection.** If the crawler
  returns zero languages and zero files, `_init_pick_recommendation`
  must still emit a sensible command (`--plan`). The early-return on
  empty data would be a silent failure.
- **File-length guardrail.** `lib/init_report.sh` is already 400 lines
  (near the 300-line M71 cap violation margin). The rewrite should
  REMOVE more than it adds. If it grows past 400, split into
  `lib/init_report_banner.sh`.
- **Watchtower compat.** The existing `_is_watchtower_enabled` branch
  swaps the "Full report" pointer to the dashboard URL. Preserve that
  behavior in the new layout — just move the line into the "What's
  next" section as an alternate.
- **Colors must match project conventions.** Reuse `${BOLD}`,
  `${GREEN}`, `${YELLOW}`, `${CYAN}`, `${NC}` already defined in
  `lib/common.sh`. Don't introduce a new color palette.

## Seeds Forward

- **First-run tutorial mode.** A future milestone could wrap the
  auto-prompt in a multi-step tutorial ("Step 1: edit pipeline.conf.
  Step 2: run --plan. Step 3: run your first milestone"). Out of scope.
- **Watchtower init view.** The same three-part banner data
  ("learned", "wrote", "next") could populate a Watchtower init panel
  so the user never has to leave the dashboard. Seed for M80/M81 work
  to converge in Watchtower V4.
- **Learning from real usage.** Track which recommended commands users
  actually run after `--init` (via causal log). If 80% of users ignore
  the recommendation, the heuristic needs tuning. Out of scope for
  M81 but easy to add.
- **Localization.** The banner is English-only. A future milestone
  could i18n it. Low priority until Tekhton has non-English users.
- **Dry-run preview.** `tekhton --init --dry-run` could show the banner
  without writing files — useful for "what would happen if I ran
  this?" Out of scope; existing `--dry-run` (M23) already covers the
  pipeline path, not init.
- **Self-healing recommendations.** If the recommended command fails
  when run, record the failure and down-weight that recommendation
  for similar projects. Requires run-memory integration. Out of scope.
