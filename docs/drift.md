# Architecture Drift Prevention

> This page used to live in the main README. It was split out in
> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md)
> to keep the README focused on the happy path.

The pipeline automatically detects and manages architectural drift across runs.

1. **Reviewer observes drift** — naming inconsistencies, layer violations, dead code, or stale patterns noted in `REVIEWER_REPORT.md`
2. **Observations accumulate** — collected in `DRIFT_LOG.md` with timestamps and task context
3. **Architect triggers** — when observations exceed threshold (default: 8) or runs since last audit exceed threshold (default: 5)
4. **Architect remediates** — produces `ARCHITECT_PLAN.md`, routing fixes to senior or jr coder by category
5. **Observations resolve** — addressed items marked RESOLVED in the drift log

**Architecture Change Proposals (ACPs)**: When the coder makes structural changes,
they propose an ACP in `CODER_SUMMARY.md`. The reviewer evaluates it. Accepted ACPs
are recorded in `ARCHITECTURE_LOG.md` with sequential ADL-NNN IDs — institutional
memory of *why* the architecture evolved.

**Human Action Required**: When the pipeline detects contradictions between design
docs and code, it creates `HUMAN_ACTION_REQUIRED.md`. A banner displays at every
pipeline completion until resolved.

**Non-Blocking Notes**: Low-priority reviewer observations accumulate in
`NON_BLOCKING_LOG.md`. When they exceed `NON_BLOCKING_INJECTION_THRESHOLD` (default: 8),
they're injected into the coder prompt on the next run for batch cleanup.

## Dependency Constraints (Optional)

Deterministic layer-boundary enforcement — no LLM judgment needed. Create an
`architecture_constraints.yaml` defining import rules, point it at a validation
script (see `examples/` for Dart, Python, TypeScript starters), and enable it
in `pipeline.conf`. The build gate runs the validator automatically. See
[examples/architecture_constraints.yaml](../examples/architecture_constraints.yaml)
for the format.
