<!-- milestone-meta
id: "20"
status: "todo"
-->

# m20 — Planning Batch + Auxiliary Bash Paths Off the Raw Claude CLI

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | June 15 cutover readiness. The planning subsystem (`--plan` interview, CLAUDE.md generation, brownfield replan, init synthesis) is still bash-canonical and calls the `claude` CLI directly, bypassing the provider seam entirely. After June 15 every planning run either fails or silently bills the metered Anthropic API. Planning is a first-class user flow, not legacy — it must follow `PROVIDER` like everything else. |
| **Gap** | (1) `lib/plan_batch.sh:88` invokes `claude` directly inside `_call_planning_batch()` — the single funnel for `stages/plan_generate.sh`, `stages/plan_interview.sh`, `stages/plan_followup_interview.sh`, replan, and init synthesis batch calls. (2) `lib/mcp_resolve.sh:158` capability-checks `claude --help` for `--mcp-config`, which both assumes the claude binary exists and gates Serena MCP on a Claude-only mechanism. (3) `lib/common.sh:175` invokes `claude usage` inside `check_usage_threshold()` (dormant by default — `USAGE_THRESHOLD_PCT=0` — but unguarded when enabled). (4) Nothing prevents a future bash file from reintroducing a raw `claude` invocation — there is no audit gate, which is how plan_batch survived the m01–m18 sweeps unnoticed. Note the funnel is wider than planning: `_call_planning_batch` also serves `lib/milestone_split.sh`, `lib/replan_midrun.sh`, and `lib/artifact_handler_ops.sh`, so fixing it covers milestone splitting and artifact merge too. |
| **m20 fills** | Rewrites `_call_planning_batch()` to build an `agent.request.v1` envelope and call `tekhton supervise` (provider-aware as of m19), preserving its contract: prints the text response to stdout, returns the agent exit code, keeps the `/dev/tty` progress indicator. Gates `lib/mcp_resolve.sh`'s claude capability check on claude actually being in the resolved provider spec (skip + warn otherwise). Adds `scripts/audit-raw-claude.sh` — a CI/test gate that fails when any file in `lib/`, `stages/`, or `tekhton*.sh` invokes the `claude` binary outside an explicit allowlist (`lib/quota_probe.sh` until m21 lands, then empty). |
| **Depends on** | m19 |
| **Files changed** | `lib/plan_batch.sh`, `lib/mcp_resolve.sh`, `lib/common.sh`, `scripts/audit-raw-claude.sh` (new), `tests/test_plan_batch_provider_boundary.sh` (new), `tests/run_tests.sh` (register), `docs/v5-polyglot.md` |

---

## Design

### Sequencing note

Hard dependency on m19: `tekhton supervise` must resolve `PROVIDER` before
planning can route through it. Do not land m20 first — it would route
planning through a still-Claude-locked seam and change nothing.

### Goal 1 — `_call_planning_batch` through the supervise seam

`lib/plan_batch.sh` keeps its public contract (stdout = response text,
return = agent exit code, progress indicator on `/dev/tty`) but replaces
the direct `claude` invocation with the same envelope-write +
`tekhton supervise` + response-parse pattern `lib/agent.sh::run_agent`
uses (reuse `_shim_write_request` / response readers from
`lib/agent_shim.sh` rather than duplicating JSON assembly). Differences
from `run_agent` worth preserving, not redesigning:

- Planning calls are *batch* (no tool loop, response text captured) —
  map to the envelope's existing fields; the text lands in the response
  envelope's stdout tail / output file, whichever the supervisor
  contract provides for print-mode runs.
- The model comes from `PLAN_INTERVIEW_MODEL` / `PLAN_GENERATION_MODEL`
  / `REPLAN_MODEL` — pass through as-is; provider-side model handling
  is the provider's job (m19 Watch For).
- Label the requests `plan_interview` / `plan_generate` / `replan` so
  `PROVIDER_PLAN_GENERATE`-style per-stage overrides work for free.

### Goal 2 — provider-gate the remaining incidental claude calls

Two call sites outside the batch funnel get the same guard shape:

**`lib/mcp_resolve.sh:158`** — see below.

**`lib/common.sh:175`** — `check_usage_threshold()`'s `claude usage`
call gains the claude-in-spec + binary-on-PATH guard; when claude is
not in the resolved spec, the function returns the no-data path
silently (the feature is claude-quota-specific by nature). One guard
clause, no refactor.

#### `lib/mcp_resolve.sh` gating detail

The `claude --help | grep -q -- --mcp-config` probe at
`lib/mcp_resolve.sh:158` runs unconditionally. Wrap it: resolve the
effective provider spec (env `PROVIDER`, default `codex,claude`); only
run the claude capability probe when the spec contains `claude` AND the
binary exists on PATH. Otherwise log a one-line skip
(`MCP/Serena: claude not in provider chain — skipping claude MCP wiring`)
and return the no-MCP path. Serena-over-Codex wiring is explicitly out
of scope (record a Drift Observation if SERENA_ENABLED=true and claude
absent).

### Goal 3 — raw-claude audit gate

`scripts/audit-raw-claude.sh` (mirroring `scripts/audit-bash-env.sh`
conventions): greps `lib/ stages/ tekhton.sh tekhton-legacy.sh` for
invocations of the `claude` binary **in command position** — the regex
must match all three real-world forms: flag form (`claude --version`),
subcommand form (`claude usage`), and line-continuation form
(`claude \` with flags on following lines — this is exactly how
`lib/plan_batch.sh:88` is written today, and the audit MUST catch it;
use something like `grep -E '(^|[;&|(\`[:space:]])claude([[:space:]]|\\\\$)'`
then filter comments, `CLAUDE_` vars, `.claude` paths, and quoted-string
mentions). Hits are diffed against an allowlist embedded in the script.
Initial allowlist: `lib/quota_probe.sh` (annotated
`# provider-gated by m21 — permanent entry; the invocations remain but
are guarded`). Non-zero exit on any unlisted hit. The audit's own test
must include a positive fixture in line-continuation form. Registered
in `tests/run_tests.sh` so the suite fails on regression.

### Goal 4 — shim-boundary test

`tests/test_plan_batch_provider_boundary.sh`: source `lib/plan_batch.sh`
+ minimal deps, fake `codex` PATH shim + failing `claude` PATH shim,
`PROVIDER=codex`, call `_call_planning_batch` with a tiny prompt, assert
the response text reaches stdout and claude was never exec'd. Self-skip
without the built binary, per the shim-boundary pattern.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `lib/plan_batch.sh` | Modify | `_call_planning_batch()` routes via envelope + `tekhton supervise`; contract (stdout/exit code/progress UI) unchanged. |
| `lib/mcp_resolve.sh` | Modify | Claude capability probe gated on claude being in the provider spec and on PATH. |
| `lib/common.sh` | Modify | `check_usage_threshold()` gains the same claude-in-spec guard. |
| `scripts/audit-raw-claude.sh` | Create | Allowlist-based audit; fails on unlisted raw `claude` invocations in bash. |
| `tests/test_plan_batch_provider_boundary.sh` | Create | Shim-boundary test for planning batch under `PROVIDER=codex`. |
| `tests/run_tests.sh` | Modify | Register the audit gate + new boundary test. |
| `docs/v5-polyglot.md` | Modify | Planning-under-codex section: which planning vars still matter, per-stage override labels. |

---

## Acceptance Criteria

- [ ] `lib/plan_batch.sh` contains no `claude` in command position: `grep -E '(^|[;&|(\`[:space:]])claude([[:space:]]|\\\\$)' lib/plan_batch.sh` (the predicate that DOES match line 88 of the current file — verify it fails pre-change) returns nothing post-change.
- [ ] With `PROVIDER=codex` and a fake codex PATH shim, `_call_planning_batch` prints the shim's response text to stdout and returns exit 0 (`tests/test_plan_batch_provider_boundary.sh` passes).
- [ ] With a PATH-shim `claude` that exits 99 on any invocation, the same test run never triggers it.
- [ ] With `PROVIDER` unset (default `codex,claude`) and only claude available, `_call_planning_batch` output for a fixed fixture prompt is identical to the pre-m20 implementation's contract: response text on stdout, claude exit code returned.
- [ ] `lib/mcp_resolve.sh` skips the `claude --help` probe and logs the skip line when the resolved provider spec does not contain `claude`.
- [ ] `lib/common.sh::check_usage_threshold` makes no `claude` invocation when the resolved provider spec excludes claude (bash unit test with PATH-shim claude + `USAGE_THRESHOLD_PCT=50`).
- [ ] `scripts/audit-raw-claude.sh` exits 0 on the post-m20 tree and exits non-zero for fixtures in all three forms: `claude -p "x"`, `claude usage`, and `claude \` + continuation-line flags (asserted in the test).
- [ ] `tests/run_tests.sh` runs the audit gate; full bash suite passes.
- [ ] No regression: `bash tests/run_tests.sh` passes; planning bash unit tests (`tests/test_plan*`) pass unmodified or with assertion-only updates.
- [ ] `docs/v5-polyglot.md` gains a "Planning under non-Claude providers" subsection naming the `plan_interview`/`plan_generate`/`replan` labels.

## Watch For

- **Interactive interview vs batch:** `stages/plan_interview.sh` may use streaming/interactive claude behavior beyond plain print-mode. Verify what `_call_planning_batch` callers actually need before assuming pure batch; if the interview path needs a capability the supervise seam lacks, surface a Drift Observation rather than bolting flags onto the envelope.
- **300-line ceiling:** `lib/plan_batch.sh` rewrite must stay under 300 lines; reuse `lib/agent_shim.sh` helpers instead of inlining JSON assembly.
- **Don't break `--draft-milestones` / dry-run:** they already go through `run_agent` and are covered by m19 — touching them here is scope creep.
- **Audit-gate false positives:** docs, prompts/, templates/, and comments legitimately mention `claude`; the audit must match invocations, not strings. Test both directions (catches a real call; ignores a comment).
- **quota_probe allowlist entry is permanent**, not temporary: m21 guards those invocations behind provider/tier gates but the text of the calls remains, so a textual audit will always flag them. Annotate the entry accordingly — do not promise its removal.
- **Per-stage overrides and MCP gating:** the mcp_resolve guard reads the global `PROVIDER` only; a `PROVIDER_<STAGE>` override that adds claude for one stage won't re-enable claude MCP wiring. Acceptable for m20 — note it in the skip log line.

## Seeds Forward

- **m21:** adds the provider/tier guards inside `lib/quota_probe.sh`; the audit allowlist entry stays (annotated), and m21's tests prove the guarded calls never fire when claude is out of the chain.
- **m23 (zero-claude verification):** planning is exercised in the no-claude smoke; this milestone is what makes that pass.
- **Future planning port to Go:** routing planning through the envelope seam now means the eventual Go port of plan/interview changes transport, not behavior.
