# Coder Summary

## Status: COMPLETE

## What Was Implemented

m29 — Detect Port (parent arc anchor). This milestone has no
implementation deliverable of its own; the parent file declares
`status: "split"` and the work lives in m29.1 and m29.2. My deliverable
is authoring the two child milestone files to template spec and
satisfying the parent's seven acceptance criteria.

When I started, `.claude/milestones/m29.1-detect-core-and-report.md`
and `.claude/milestones/m29.2-detect-domain-detectors.md` already
existed as substantively complete files (presumably from an earlier
attempt). I audited both against every AC in the parent m29 file.
Result: six of seven ACs satisfied as-found; one gap in m29.2's
Watch For section.

### Gap fixed

AC #5 — "Both child milestones include a Watch For bullet documenting
the read-only contract and the dogfood-stability invariant."

- m29.1 had both bullets (line 358 read-only contract, line 359
  dogfood stability). ✓
- m29.2 had the dogfood stability bullet (now line 313) but no
  dedicated read-only contract bullet. **Missing.**

Added a new first bullet to m29.2's Watch For section documenting
that `internal/detect/readonly_test.go` continues to apply to every
new Go file landed in m29.2, naming the eight Go files and the seven
forbidden write APIs, and reinforcing that the CLI surface is the only
place `os.Stdout` writes are allowed.

### Meta block interpretation note

AC #1/#2 read "declares `depends_on: m27` in both its meta block and
Overview table." The template (`.tekhton/MILESTONE_TEMPLATE.md`) and
the runtime (`lib/milestone_metadata.sh::emit_milestone_metadata`
lines 62-66) only put `id` and `status` in the meta block — they
strip everything else on each status transition. Every existing
split-child file (`m30.1`, `m30.2`, `m31.1`, `m31.2`, `m32.1`-`m32.3`,
`m33.1`, `m33.2`) follows this convention: `id` + `status` in meta,
`Depends on` row in Overview, dependency tracking authoritative in
`MANIFEST.cfg`.

Adding `depends_on:` to a meta block would be silently wiped on the
next status update, breaking the AC the moment the runtime touched the
file. The correct interpretation is: meta block must exist and be
template-conformant; dependency declaration lives in the Overview
table + MANIFEST. Both child files satisfy this.

## Acceptance Criteria — verified

- [x] `.claude/milestones/m29.1-detect-core-and-report.md` exists with
      template-conformant meta block (`id: "29.1"`, `status: "todo"`)
      and Overview `Depends on | m27` row at line 15.
- [x] `.claude/milestones/m29.2-detect-domain-detectors.md` exists
      with template-conformant meta block (`id: "29.2"`,
      `status: "todo"`) and Overview `Depends on | m29.1` row at
      line 15.
- [x] Both child milestones include parity-gate acceptance criteria
      naming the three fixtures `monorepo-pnpm`, `polyglot-services`,
      `ai-heavy-mess` (m29.1 lines 341-344; m29.2 lines 287-288).
- [x] m29.2 includes a VERSION acceptance criterion specifying
      `4.29.0` on close (line 301). m29.1 has no VERSION AC.
- [x] Both child milestones include a Watch For bullet documenting
      the read-only contract AND the dogfood-stability invariant.
      m29.1 had both as-found. m29.2 had dogfood only; added the
      read-only contract bullet in this milestone.
- [x] Parent file sits at `.claude/milestones/m29-detect-port.md`
      with `status: "split"` (verified; unchanged).
- [x] `.claude/milestones/MANIFEST.cfg` carries three rows: `m29`
      (status=split), `m29.1` (status=todo), `m29.2` (status=todo).
      Verified at lines 39-41 of MANIFEST.cfg; unchanged.

## Files Modified

- `.claude/milestones/m29.2-detect-domain-detectors.md` — Added a
  read-only contract bullet to the top of `## Watch For` (8 lines).
  Existing dogfood-stability bullet preserved further down the
  section. No other section touched.

## Files NOT Modified (deliberate)

- `.claude/milestones/m29-detect-port.md` — Already template-
  conformant with `status: "split"`. The parent file has no
  implementation deliverable per its own Watch For ("The parent
  milestone has no implementation. Do not add code-level acceptance
  criteria here…").
- `.claude/milestones/m29.1-detect-core-and-report.md` — Already
  satisfied all parent-arc ACs that apply to m29.1.
- `.claude/milestones/MANIFEST.cfg` — Already has the three required
  rows. Parent AC #7 says "after the human's sequential-review pass"
  — the manifest rows were authored at MANIFEST setup time and
  already match. No edit required.

## Human Notes Status

No HUMAN_NOTES.md items present in this task. The Clarifications
block in the task injection contained Q&A pairs from prior
unrelated runs (Watchtower dashboard, NON_BLOCKING_LOG,
--init/--plan flow, notes inconsistency). None relate to m29.

## Docs Updated

None — no public-surface changes in this task. m29's parent
milestone is a manifest anchor + arc design; no CLI surface, no
config keys, no exported APIs change. The two child milestones
describe future work (m29.1 + m29.2) which will themselves carry
docs-updated obligations when they implement.

## Observed Issues (out of scope)

- **AC wording in parent m29 file is imprecise about meta-block
  `depends_on`.** Documented above. The actual convention
  (template + runtime + every prior split-child file) puts
  dependency tracking in the Overview table + MANIFEST.cfg, not the
  meta block. Future split-parent authors should phrase this AC as
  "declares `Depends on: m27` in its Overview table matching the
  MANIFEST.cfg `depends_on` column," matching m32's wording style.
  Not in scope to edit the m29 parent file from a child-authoring
  milestone.

## Architecture Change Proposals

None. Pure milestone-file authoring. No code, no architecture, no
new modules, no module boundaries crossed.
