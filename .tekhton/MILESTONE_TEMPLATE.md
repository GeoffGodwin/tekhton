<!--
================================================================================
TEKHTON MILESTONE FILE TEMPLATE — canonical authoring format

This template is the single source of truth for Tekhton milestone files
(`.claude/milestones/m<NN>-<slug>.md`). Every new milestone copies this
file as a starting point. The structure here is the one the rest of the
toolchain expects to consume:

  - `lib/milestone_dag.sh`          reads the meta block for id + status
  - `lib/milestone_acceptance*.sh`  parses `## Acceptance Criteria` checkboxes
  - `lib/milestone_archival.sh`     copies completed bodies to MILESTONE_ARCHIVE.md
  - `lib/milestone_progress*.sh`    renders `## Overview` + `## Acceptance Criteria`
  - `tools/release_notes/*`         pulls the H1 title and `m<NN> fills` row

Format rules (deviating from these has burned us in the past — keep them):

  1. The `<!-- milestone-meta ... -->` block MUST be the very first content
     in the file, BEFORE the H1. The id field is a quoted string; the
     status field is one of: todo | in_progress | done | skipped.

  2. The H1 title format is `# m<NN> — <Title Case Title>`:
     - lowercase `m`, NOT uppercase `M`
     - em dash `—`, NOT a hyphen
     - the `<NN>` is the same id as in the meta block, no zero-padding above 99
     The runtime tolerates older `# M<NN> - ...` titles for backwards
     compatibility but the linter flags them as legacy.

  3. The section order is fixed:
       ## Overview
       ## Design
       ## Files Modified
       ## Acceptance Criteria
       ## Watch For
       ## Seeds Forward
     `## Implementation Notes`, `## Exit Stage`, `## Exit Reason`, `## Task`,
     and `## Notes` are runtime-injected during execution and MUST NOT be
     authored into the template — they appear only in completed milestones.

  4. The `## Overview` block uses the table form below. Five rows are
     required (Arc motivation, Gap, m<NN> fills, Depends on, Files
     changed). The optional `### Prior arc context` sub-table only appears
     when this milestone is part of a multi-milestone arc.

  5. The `## Files Modified` table has three columns: File / Change type /
     Description. Use backticks for paths. Change type is one of:
     Add | Modify | Create | Delete | Add + modify.

  6. `## Acceptance Criteria` is a flat checkbox list. Each item must be
     observable (a test passes, a function returns X, a file contains Y) —
     no aspirational items. The acceptance linter (m85) rejects vague
     wording.

  7. `## Watch For` lists pitfalls a future implementer needs to know about
     — sequencing constraints, related-but-out-of-scope items, easy-to-miss
     edge cases. Two to six bullets is the typical range.

  8. `## Seeds Forward` records what later milestones will lean on from
     this one. Two to six bullets. Use **bold lead-ins** to make them
     scannable.

  9. The dependencies declared in the `Depends on` row of `## Overview`
     MUST match the `depends_on` column of the entry in MANIFEST.cfg.
     Drift between the two breaks resume routing and is a known foot-gun.

REMOVE THIS COMMENT BLOCK BEFORE COMMITTING the milestone file.
================================================================================
-->

<!-- milestone-meta
id: "<NN>"
status: "todo"
-->

# m<NN> — <Title Case Title>

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | <Why this milestone exists in the larger arc — the user-visible behavior or system property that doesn't work today.> |
| **Gap** | <What's missing in the current code or design that this milestone closes. Cite specific files / functions / configs.> |
| **m<NN> fills** | <One-paragraph description of what this milestone delivers. Should read as a mini abstract.> |
| **Depends on** | <m##, m## — list of milestone ids whose work this one builds on; matches MANIFEST.cfg `depends_on` column> |
| **Files changed** | <Comma-separated list of the principal files this milestone touches.> |

<!-- Optional: include the Prior arc context table only when this milestone is
     part of a named multi-milestone arc (e.g. resilience arc m126–m138). -->

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m<NN-2> | <one-line concern> |
| m<NN-1> | <one-line concern> |
| **m<NN>** | **<this milestone's concern>** |

---

## Design

<!-- Open with a short framing paragraph if the milestone has more than one
     goal or a non-obvious sequencing constraint. Use `### Sequencing note`
     when the milestone must land after another in-flight milestone or
     edits files the prior milestone introduces. -->

### Sequencing note

<Optional. Drop this subsection if there's nothing to sequence around.>

### Goal 1 — <succinct goal label>

<Design narrative for goal 1. Include code snippets, tables, file paths.
Be concrete enough that an implementer can follow without rediscovering
the design. Cite line numbers (`lib/foo.sh:123`) where it helps anchor.>

```bash
# Code samples are encouraged when the design depends on a specific shape.
foo() {
    :
}
```

### Goal 2 — <succinct goal label>

<...>

### Goal N — <succinct goal label>

<...>

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `<path/to/file.sh>` | Add + modify | <What functions/sections change and why.> |
| `<path/to/test.sh>` | Create | <Scope of new test coverage.> |
| `<templates/x.example>` | Modify | <Surface-level change description.> |

---

## Acceptance Criteria

<!-- Each item must be observable. The m85 acceptance linter rejects vague
     wording like "is correct", "works as expected", "handles edge cases".
     Prefer concrete predicates: "function X returns 0 when …", "file Y
     contains line Z", "test T passes". -->

- [ ] <Concrete, testable predicate.>
- [ ] <Concrete, testable predicate.>
- [ ] <Concrete, testable predicate.>
- [ ] All new tests pass: <list of test files added in this milestone>.
- [ ] No regression in <names of related existing test files>.
- [ ] Documentation updated where relevant (`README.md`, `docs/<topic>.md`,
      template comments in `templates/pipeline.conf.example`, …).

## Watch For

<!-- Pitfalls and gotchas. Two to six bullets. Topics that earned a slot
     here in past milestones: sourcing-order dependencies, runtime-vs-
     authoring-time invariants, foot-guns the previous milestone left
     behind, files that look related but must not be touched. -->

- <Pitfall, gotcha, sequencing constraint, or out-of-scope reminder.>
- <…>

## Seeds Forward

<!-- What does this milestone set up for future work? Bold the lead-in
     so future authors can scan for inheritance lines. -->

- **<Future milestone or topic>:** <How this milestone unblocks or shapes it.>
- **<Future milestone or topic>:** <…>
