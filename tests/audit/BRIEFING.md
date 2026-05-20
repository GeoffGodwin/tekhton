# Test Suite Audit — Agent Briefing

You are auditing a slice of Tekhton's test suite for stale tests.

## Background

Tekhton is mid-Ship-of-Theseus migration from bash to Go (V4). V3 ran for
138 milestones, all archived. V4 has completed m01-m22 + m26. Many bash tests
were written against bash logic that no longer exists — it was wedged into Go
or deleted outright.

## What has been wedged to Go (test for this in bash → suspicious)

| V4 Milestone | Subsystem | Go package(s) | Old bash (mostly gone or shim) |
|---|---|---|---|
| m02 | Causal log | `internal/causal` | `lib/causality.sh`, `lib/causality_query.sh` (shimmed) |
| m03 | Pipeline state | `internal/state` | `lib/state.sh` (largely gone) |
| m06-m10 | Supervisor (agent CLI invocation, retry, quota, fsnotify) | `internal/supervisor` | `lib/agent.sh` is a thin shim now; pre-m10 bash retry/quota logic is gone |
| m12 | Orchestrate loop | `internal/orchestrate` | `lib/orchestrate*.sh` (shimmed) |
| m13 | Manifest parser | `internal/manifest` | `lib/milestone_dag_io*.sh` (shim) |
| m14 | Milestone DAG state machine | `internal/dag` | `lib/milestone_dag.sh`, `lib/milestone_query.sh` (shims) |
| m15 | Prompt template engine | `internal/prompt` | `lib/prompts.sh`, `lib/prompts_io.sh` (shims) |
| m16 | Config loader | `internal/config` | `lib/config.sh`, `lib/config_defaults.sh` (shims) |
| m17 | Error taxonomy | `internal/errors` | `lib/errors.sh` (shim), `lib/remediation.sh` |
| m18 | Pipeline runner + stage adapter | `internal/pipeline`, `internal/stagerunner` | New surface; old `tekhton.sh` flow is now dispatcher-only |
| m19 | `tekhton run` top-level | `cmd/tekhton` | Replaced bash dispatcher main flow |
| m21 | Finalize orchestrator | `internal/finalize` | `lib/finalize*.sh` reduced to hooks |
| m22 | Preflight | `internal/preflight` | All `lib/preflight*.sh` **deleted** |
| m26 | Stage and finalize env contract | `internal/stagerunner` env wiring | New behavior — tests should be Go-side |

## What is still bash (tests here → likely KEEP)

- Stage scripts: `stages/*.sh` (coder, security, review, tester, intake, docs, cleanup, plan_*, etc.)
- Stage-internal helpers: `lib/coder_buildfix*.sh`, `lib/tester_*.sh`, `lib/review*.sh`, etc.
- TUI bash glue: `lib/tui*.sh` (sidecar manager — Python sidecar is in `tools/tui*.py`)
- Project intelligence: `lib/detect*.sh`, `lib/crawler*.sh`, `lib/indexer*.sh`, `lib/init*.sh`
- Drift / milestones / notes / docs agent / specialists: most `lib/{drift,milestone_split,notes,docs,specialists}*.sh`
- Dashboard / Watchtower: `lib/dashboard*.sh`
- Health / metrics: `lib/health*.sh`, `lib/metrics*.sh`
- Build/test gate runtime glue (the parts not in the Go runner)

When in doubt, **assume bash is still live unless you can show its file was deleted or shimmed**.
Check with: `ls -la lib/<file>.sh` or `wc -l lib/<file>.sh` — shims are typically <50 lines and exec `tekhton <subcommand>`.

## Verdict criteria

Assign one of these per test:

- **KEEP** — Test exercises bash that is still live (file exists, has logic, not a shim).
- **DELETE-STALE** — Bash logic the test targeted has been removed or shimmed AND the Go side has its own test for the same behavior. Positive evidence required.
- **PORT-TO-GO** — Behavior still matters but the implementation moved to Go and the Go side does NOT yet have an equivalent test. Recommend porting.
- **NEEDS-REVIEW** — Ambiguous. Test mixes live and dead concerns, or you cannot tell without deeper context. Flag for human.
- Default to **KEEP** when uncertain. We can re-audit later; we cannot un-delete cheaply.

## How to audit each test

1. Read the test file (most are short, 50-200 lines).
2. Identify what it claims to test: which `lib/*.sh` or `stages/*.sh` file? Which functions? Which behaviors?
3. Check those targets exist and contain real logic (`ls`, `wc -l`, `grep` for the function names).
4. Cross-reference Go tests: `find internal -name "*_test.go" | xargs grep -l <relevant-keyword>` to detect duplication.
5. Apply the verdict criteria. **Don't recommend DELETE without positive evidence.**

## Output

Write a single markdown file at `tests/audit/<bucket>.md` with this structure:

```markdown
# Bucket <X> Audit — <domain>

Audited N tests. Verdict counts: KEEP=A, DELETE-STALE=B, PORT-TO-GO=C, NEEDS-REVIEW=D.

## Verdicts

| Test | Verdict | Reason |
|---|---|---|
| test_foo.sh | KEEP | Exercises stages/foo.sh:bar(), still live |
| test_bar.sh | DELETE-STALE | Targets lib/preflight*.sh — all deleted in m22; internal/preflight has coverage |
| test_baz.sh | PORT-TO-GO | Tests config var validation; lib/config.sh is now a shim, internal/config lacks equivalent test |
| test_qux.sh | NEEDS-REVIEW | Mixes live drift glue with dead state.sh path |

## Coverage gaps noted

- Brief bullet points if you noticed missing tests during the audit. Don't go looking — just note things you stumbled across.
```

Be concise in the Reason column — one sentence. Don't pad.

## Guardrails

- **You are read-only.** Do not delete, edit, or move any test. Produce recommendations only.
- **Stale claims need evidence.** If you say "DELETE-STALE", the reason must point to a deleted/shimmed file or a Go test that covers the same ground. Vague "looks old" is not evidence.
- **Don't audit outside your bucket.** Stick to the list you're given.
