
# Milestone 75: Dedicated Docs Agent Stage (Optional, Haiku-Powered)
<!-- milestone-meta
id: "75"
status: "done"
-->
<!-- PM-tweaked: 2026-04-12 -->

## Overview

M74 bakes documentation awareness into the existing coder and reviewer
prompts — that's the cheap, always-on fix. M75 adds an **optional** fast
stage that runs between coder and reviewer, using a Haiku-tier model to
read the coder's diff + `## Docs Updated` declaration and produce concrete
README/docs patches.

Motivation: coders under turn pressure will sometimes skip doc updates
entirely, or write a one-line README bump when the surface they touched
needs a full paragraph refresh. A purpose-built agent with a narrow job
("given this diff, fix the docs to match") is cheaper and better at this
than asking the coder to do it in a side-quest.

This stage is **off by default**. Projects opt in by setting
`DOCS_AGENT_ENABLED=true` in `pipeline.conf`. When off, M74's bake-in
behavior still runs — the only thing that changes is whether a dedicated
agent validates/updates docs between coder and reviewer.

Depends on **M74** — the coder must already be writing
`## Docs Updated` to `CODER_SUMMARY.md`, and the pipeline must already
know what "public surface" means for the project (CLAUDE.md section 13).

## Design Decisions

### 1. New stage, not a specialist

This could be implemented as a new specialist review (joining security,
performance, API, UI). It's implemented as its own stage because:

- Specialists run in parallel as a review panel; the docs agent needs to
  **write files** (README, docs/ pages), not just report findings.
- Specialists block review cycles based on severity; the docs agent
  should never block. It either updates docs or reports "no update
  needed" — no rework loop.
- Specialists read `CODER_SUMMARY.md`; the docs agent needs the raw git
  diff too so it can reason about renamed symbols.

So: new file `stages/docs.sh`, new prompt `prompts/docs_agent.prompt.md`,
invoked from `tekhton.sh` between the coder build gate and the security
stage.

### 2. Pipeline position: after build gate, before security

```
coder → build gate → [docs agent] → security → reviewer → tester
```

Rationale:

- **Must run after build gate** — if the build is broken, the diff is
  half-finished. Updating docs against a half-finished API is wasted
  work.
- **Before security** — security may request rework that changes the
  public surface again. If docs ran after security, every security-induced
  rework would invalidate the docs agent's work. Running before means
  the docs agent's output is part of what security scans (good —
  README diffs should also pass security's secret-detection).
- **Before reviewer** — the reviewer needs `## Docs Updated` to already
  reflect the agent's contributions, not the coder's initial declaration.

### 3. Haiku by default, configurable

```bash
: "${DOCS_AGENT_MODEL:=claude-haiku-4-5-20251001}"
: "${DOCS_AGENT_MAX_TURNS:=10}"
```

Docs writing is a narrow, well-bounded task. Haiku is plenty. Users who
want higher-quality docs can upgrade to Sonnet or Opus via config, same
pattern as every other stage.

### 4. Skip-path: no public surface changed

Before invoking the agent, the stage runs a single quick check: did
the coder's diff touch anything listed in CLAUDE.md's "public surface"
declaration (section 13, added by M74)?

If no public-surface files changed, the stage logs "nothing to do" and
returns 0 without invoking an agent. This saves tokens on routine
internal-refactor milestones. The check is intentionally narrow —
deciding whether the coder's `## Docs Updated` section is "complete
enough" is a judgment call we leave to the agent itself. If the agent
runs and concludes no updates are needed, it just writes an empty
report and exits. That's an acceptable cost compared to the risk of
a heuristic false-skip.

### 5. Output contract

The docs agent writes two artifacts:

1. **Actual file modifications** to `README.md` / `docs/*.md`, committed
   in-place (the agent uses its Edit/Write tools directly — same as the
   coder).
2. **A report file:** `${TEKHTON_DIR}/DOCS_AGENT_REPORT.md` — lists what
   it updated, what it couldn't figure out, and any open questions for
   the reviewer. This flows into the causal log and metrics.

If the agent fails turn-exhaustion mid-edit, it records which files it
started modifying. The pipeline can re-run the stage on resume without
double-editing.

### 6. Interaction with M74's `## Docs Updated` marker

After the docs agent runs, it APPENDS any files it touched to the
`## Docs Updated` section of `CODER_SUMMARY.md` (creates the section if
the coder didn't). This means the reviewer's freshness check in M74
sees both coder-updated and agent-updated files in one list — it
doesn't need to know the agent ran.

### 7. `--skip-docs` flag

Add `--skip-docs` to `tekhton.sh` arg parsing, matching the existing
`--skip-security` pattern. Useful for fast iteration during debugging
where docs work is genuinely wasted effort.

### 8. Watchtower integration

The docs stage emits stage start/end events to the causal log the same
way every other stage does. Watchtower's existing full-stage metrics
(M66) will pick it up automatically — no Watchtower-side code change
required.

## Migration Impact

[PM: Added — milestone introduces 6 new config keys and a new CLI flag.]

All changes are **backward-compatible**. No action is required for existing
projects:

- `DOCS_AGENT_ENABLED` defaults to `false` — the stage is a no-op unless
  explicitly opted in. Existing pipelines behave identically.
- `DOCS_AGENT_MODEL`, `DOCS_AGENT_MAX_TURNS`, `DOCS_AGENT_REPORT_FILE`,
  `DOCS_README_FILE`, and `DOCS_DIRS` are only read when
  `DOCS_AGENT_ENABLED=true`. Unused otherwise.
- `--skip-docs` is additive; existing CLI invocations are unaffected.
- No `pipeline.conf` keys are renamed, removed, or given new semantics.
- No existing stage positions or stage-count values change unless the new
  feature is explicitly enabled.

Projects that want the docs stage add one line to `pipeline.conf`:
```bash
DOCS_AGENT_ENABLED=true
```

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| New stage file | 1 | `stages/docs.sh` |
| New prompt file | 1 | `prompts/docs_agent.prompt.md` |
| New lib helpers | 1 | `lib/docs_agent.sh` — skip-path detection, public-surface parsing |
| New config variables | 6 | `DOCS_AGENT_ENABLED`, `DOCS_AGENT_MODEL`, `DOCS_AGENT_MAX_TURNS`, `DOCS_AGENT_REPORT_FILE`, `DOCS_README_FILE`, `DOCS_DIRS` (`SKIP_DOCS` is a CLI-set runtime var, not in `config_defaults.sh`) |
| Pipeline integration | 1 | `tekhton.sh` main loop — insert between build gate and security |
| CLI flag | 1 | `--skip-docs` |
| Tests added | 2 | `test_docs_agent_skip_path.sh`, `test_docs_agent_stage_smoke.sh` |

## Implementation Plan

### Step 1 — Config + template variables

Edit `lib/config_defaults.sh`:

```bash
# --- Docs agent (M75) ---
# Optional post-coder/pre-security stage that uses a fast model to
# read the coder diff and update README/docs/ accordingly. Depends on
# M74 bake-in behavior to provide the `## Docs Updated` handshake.
: "${DOCS_AGENT_ENABLED:=false}"
: "${DOCS_AGENT_MODEL:=claude-haiku-4-5-20251001}"
: "${DOCS_AGENT_MAX_TURNS:=10}"
: "${DOCS_AGENT_REPORT_FILE:=${TEKHTON_DIR}/DOCS_AGENT_REPORT.md}"
: "${DOCS_README_FILE:=${PROJECT_DIR}/README.md}"
: "${DOCS_DIRS:=${PROJECT_DIR}/docs}"
```

[PM: Added `DOCS_README_FILE` (default: `${PROJECT_DIR}/README.md`) and
`DOCS_DIRS` (default: `${PROJECT_DIR}/docs`) — the prompt template (Step 3)
references `{{DOCS_README_FILE}}` and `{{DOCS_DIRS}}` but neither had a
config default or `lib/prompts.sh` registration entry. Without these, the
rendered prompt would contain unresolved `{{VAR}}` tokens at runtime.]

Edit `lib/prompts.sh` — register all six vars as template variables.

### Step 2 — Skip-path detection helper

Create `lib/docs_agent.sh` with one main function:

```bash
# docs_agent_should_skip
#   Returns 0 if the stage should skip (no work to do), 1 if it should run.
#
#   Skip criteria (any one suffices):
#   - DOCS_AGENT_ENABLED != true
#   - SKIP_DOCS == true
#   - No changed files from the coder touch anything listed as public surface
#     in CLAUDE.md section 13 (parsed via grep — cheap and forgiving)
docs_agent_should_skip() { ... }
```

The "public surface" check reads the Documentation Responsibilities
section of CLAUDE.md (added by M74) and extracts the list of surfaces.
Surfaces are matched against changed files via path globs. If no match,
the stage skips.

Keep the helper simple — don't try to parse CLAUDE.md as structured
data. A forgiving grep is fine: if the agent runs when it didn't
strictly need to, the agent itself will report "nothing to update" and
return. The cost of a false-positive skip is worse than a false-negative
skip, so bias toward running the agent.

### Step 3 — Docs agent prompt

Create `prompts/docs_agent.prompt.md`. System prompt establishes the
agent as a documentation maintainer. Key sections:

- **Inputs**
  - `{{CODER_SUMMARY_FILE}}` contents (what the coder did)
  - `{{PROJECT_DIR}}` and the list of files they changed
  - `{{DOCS_README_FILE}}` and `{{DOCS_DIRS}}` — where docs live
  - CLAUDE.md section 13 contents — the declared public surface
- **Task**
  - Read each modified source file and compare to existing documentation
  - For any public-surface change (flag, API, config key, route, schema)
    not already reflected in docs, update the relevant file
  - Preserve prose tone — match the existing README's voice
  - Do NOT reformat entire files — minimal targeted edits
  - If you can't figure out what a change does, flag it in the report
    rather than guessing
- **Output**
  - File edits (direct)
  - Append to `{{CODER_SUMMARY_FILE}}` — a `## Docs Updated` subsection
    listing every file touched in this stage
  - Write `{{DOCS_AGENT_REPORT_FILE}}` — summary + open questions

Keep the prompt under 200 lines. The narrower the agent's focus, the
better Haiku performs.

### Step 4 — Stage file

Create `stages/docs.sh`. Model on `stages/security.sh` for structure:

```bash
run_stage_docs() {
    local _stage_count="${PIPELINE_STAGE_COUNT:-5}"
    local _stage_pos="${PIPELINE_STAGE_POS:-2}"
    header "Stage ${_stage_pos} / ${_stage_count} — Docs"

    if [[ "${DOCS_AGENT_ENABLED:-false}" != "true" ]]; then
        log "[docs] Docs agent disabled (DOCS_AGENT_ENABLED=false). Skipping."
        return 0
    fi
    if [[ "${SKIP_DOCS:-false}" == "true" ]]; then
        log "[docs] Docs stage skipped (--skip-docs). Skipping."
        return 0
    fi
    if docs_agent_should_skip; then
        log "[docs] No public-surface changes. Skipping."
        return 0
    fi

    local docs_turns="${DOCS_AGENT_MAX_TURNS:-10}"
    local prompt
    prompt=$(render_prompt docs_agent)

    run_agent "docs" "$prompt" "${DOCS_AGENT_MODEL}" "$docs_turns" || {
        warn "[docs] Docs agent run failed — continuing pipeline without docs updates"
        return 0
    }

    log "[docs] Docs agent finished. Report: ${DOCS_AGENT_REPORT_FILE}"
    return 0
}
```

Note: the stage never returns non-zero. Docs updates are best-effort —
a broken docs agent run should not kill the pipeline.

### Step 5 — Pipeline integration in `tekhton.sh`

Find the main pipeline loop. Source `stages/docs.sh` alongside other
stages. Insert the docs stage call between the build gate (end of
`run_stage_coder`) and the start of `run_stage_security`.

The stage-count variables (`PIPELINE_STAGE_COUNT`, `PIPELINE_STAGE_POS`)
need to be updated: when `DOCS_AGENT_ENABLED=true`, the pipeline has
one more stage, so the count goes from (typically) 4 to 5 and every
downstream stage's position shifts by 1. Use a helper
`_compute_pipeline_stage_count` in `lib/common.sh` or similar that
reads all the enabled flags once at startup rather than hardcoding.

### Step 6 — CLI flag plumbing

Edit `tekhton.sh` arg parser. Add `--skip-docs` handling that sets
`SKIP_DOCS=true`. Update `--help` text. Mention in README under the
CLI reference.

### Step 7 — Tests

Create `tests/test_docs_agent_skip_path.sh`:

1. Set up a fake project where coder changed only an internal helper.
   Assert `docs_agent_should_skip` returns 0 (skip).
2. Change a file that matches a public-surface path from CLAUDE.md
   section 13. Assert `docs_agent_should_skip` returns 1 (run).
3. Set `DOCS_AGENT_ENABLED=false`. Assert skip regardless of diff.
4. Set `SKIP_DOCS=true`. Assert skip regardless of diff.

Create `tests/test_docs_agent_stage_smoke.sh`:

1. Stub out `run_agent` to echo what it was called with.
2. Run `run_stage_docs` with a public-surface diff.
3. Assert the stub was called with model = `DOCS_AGENT_MODEL` and
   turn budget = `DOCS_AGENT_MAX_TURNS`.
4. Assert the stage returned 0.
5. Run with the stub configured to fail — assert the stage still
   returns 0 (docs failures are non-blocking).

Register both in `tests/run_tests.sh`.

### Step 8 — Shellcheck + full test suite

```bash
shellcheck stages/docs.sh lib/docs_agent.sh tekhton.sh
bash tests/run_tests.sh
```

### Step 9 — Version bump + manifest

Edit `tekhton.sh` — `TEKHTON_VERSION="3.75.0"`.
Edit `.claude/milestones/MANIFEST.cfg` — add M75 row with `depends_on=m74`,
group `quality`.

## Files Touched

### Added
- `stages/docs.sh`
- `prompts/docs_agent.prompt.md`
- `lib/docs_agent.sh`
- `tests/test_docs_agent_skip_path.sh`
- `tests/test_docs_agent_stage_smoke.sh`
- `.claude/milestones/m75-docs-agent-stage.md` — this file

### Modified
- `lib/config_defaults.sh` — six new `DOCS_AGENT_*` / `DOCS_*` vars
- `lib/prompts.sh` — register new template variables
- `tekhton.sh` — source `stages/docs.sh`, invoke `run_stage_docs`,
  add `--skip-docs` flag, update stage-count helper, bump version
- `lib/common.sh` (or equivalent) — stage-count helper if not already present
- `tests/run_tests.sh` — register new tests
- `.claude/milestones/MANIFEST.cfg` — M75 row

## Acceptance Criteria

- [ ] `stages/docs.sh` exists and defines `run_stage_docs`
- [ ] `prompts/docs_agent.prompt.md` exists and references `{{CODER_SUMMARY_FILE}}`,
      `{{DOCS_README_FILE}}`, `{{DOCS_DIRS}}`, `{{DOCS_AGENT_REPORT_FILE}}`
- [ ] `lib/docs_agent.sh` defines `docs_agent_should_skip`
- [ ] `lib/config_defaults.sh` defines all six new `DOCS_AGENT_*` / `DOCS_*` vars with the correct defaults
- [ ] `DOCS_AGENT_ENABLED` defaults to `false`
- [ ] `DOCS_AGENT_MODEL` defaults to `claude-haiku-4-5-20251001`
- [ ] `DOCS_README_FILE` defaults to `${PROJECT_DIR}/README.md`
- [ ] `DOCS_DIRS` defaults to `${PROJECT_DIR}/docs`
- [ ] `tekhton.sh` sources `stages/docs.sh` and invokes `run_stage_docs`
      between build gate and security stage
- [ ] `tekhton.sh` supports `--skip-docs` flag and updates `--help` text
- [ ] Pipeline stage-count accounts for the docs stage when
      `DOCS_AGENT_ENABLED=true`
- [ ] `run_stage_docs` returns 0 on agent failure (non-blocking)
- [ ] `docs_agent_should_skip` returns 0 when no public-surface files changed
- [ ] `docs_agent_should_skip` returns 1 when public-surface files changed
- [ ] Docs agent appends its touched files to `CODER_SUMMARY.md`'s
      `## Docs Updated` section (so M74's reviewer check sees them)
- [ ] Docs agent writes `DOCS_AGENT_REPORT_FILE` on every run
- [ ] `tests/test_docs_agent_skip_path.sh` passes
- [ ] `tests/test_docs_agent_stage_smoke.sh` passes
- [ ] `bash tests/run_tests.sh` passes with zero failures
- [ ] `shellcheck stages/docs.sh lib/docs_agent.sh tekhton.sh` reports
      zero warnings
- [ ] `tekhton.sh` `TEKHTON_VERSION` is `3.75.0`
- [ ] `.claude/milestones/MANIFEST.cfg` contains the M75 row with
      `depends_on=m74`, group `quality`

## Watch For

- **Depends on M74 landing first.** Do NOT attempt M75 before M74 — the
  `## Docs Updated` handshake and CLAUDE.md section 13 are prerequisites.
  M74 is in the manifest with `depends_on=m72`; M75's `depends_on=m74`.
- **Non-blocking failure mode.** The docs stage must NEVER kill the
  pipeline. If Haiku is unavailable, rate-limited, or turns out, log a
  warning and continue to security. Docs updates are best-effort. The
  reviewer (via M74) will catch serious doc regressions independently.
- **Skip-path correctness.** False positive (skip when we should run)
  is better than false negative (run when we shouldn't), because a
  false-negative spends tokens and can make a noisy "nothing to change"
  commit. Err toward skipping.
- **Rework loop re-runs are handled by the same skip check.** When the
  security or reviewer stage triggers a rework, the coder re-runs. The
  docs stage runs again too — but the same `docs_agent_should_skip`
  check applies. If the rework diff doesn't touch public-surface files,
  the stage skips without invoking the agent. No special-casing of
  `REVIEW_CYCLE` is required.
- **Parser forgiveness for CLAUDE.md section 13.** Section 13 is free-form
  markdown. Don't try to parse it as structured data. Extract file globs
  and path patterns via regex, then match against changed-file paths.
  If parsing fails, run the agent anyway — it can read CLAUDE.md itself.
- **Prompt length discipline.** Haiku performs best on focused prompts
  under ~200 lines. Resist the urge to stuff context. Give it the diff,
  the README, and the docs dir listing — that's it. CLAUDE.md section 13
  can be a short excerpt rather than the full file.
- **`run_agent` signature consistency.** Use the existing `run_agent`
  helper in `lib/agent.sh`. Don't invent a new invocation path — go
  through the same metrics/monitoring/retry stack as every other stage.
- **Stage-count update is easy to miss.** Grep `PIPELINE_STAGE_COUNT` and
  update every site that hardcodes the old count. The symptom if you
  miss one: Watchtower shows "Stage 3 / 4" when the docs stage is
  enabled — wrong total.
- **Causal log stage name.** Use `docs` as the canonical stage name in
  the causal log. Short, lowercase, matches the filename
  (`stages/docs.sh`). Watchtower (M66) will pick up the name
  automatically.
- **Report file isn't under `.claude/`.** Per M72, the report goes under
  `${TEKHTON_DIR}/DOCS_AGENT_REPORT.md` so it sits alongside other
  stage reports. Don't stash it in `.claude/logs/`.
- **Model name is a moving target.** If the Haiku 4.5 model ID changes
  before this ships, update the default. Users can always override in
  pipeline.conf.
- **`DOCS_README_FILE` and `DOCS_DIRS` are path defaults, not discovery.**
  The docs agent must verify these paths exist before editing. If
  `DOCS_README_FILE` doesn't exist or `DOCS_DIRS` is empty, the agent
  should report "nothing to do" rather than fail.

## Seeds Forward

- **Doc link checking.** A future step could call a standalone
  link-checker on `docs/` after the agent runs and flag broken links.
- **Auto-generated API refs.** When the coder touches a
  TypeDoc/Sphinx/rustdoc-covered file, the docs agent could re-run the
  generator rather than manually editing files. Out of scope for M75.
- **i18n docs.** Projects with localized docs could flag the English doc
  as updated and mark the translations as "stale." Out of scope.
- **Agent model escalation ladder.** If Haiku can't figure out a complex
  docs change and reports "needs help," the pipeline could retry with
  Sonnet. Pattern similar to the M64 tester fix surgical-mode escalation.
  Defer to a future efficiency milestone if the signal shows up in metrics.
- **Watchtower "docs" tile.** Once data flows through the existing M66
  pipeline, a dedicated docs tile in Watchtower could show per-milestone
  doc freshness score. Small follow-up.
