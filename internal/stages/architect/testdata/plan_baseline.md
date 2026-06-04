# Architect Plan

A frozen v3-format plan with every section populated. Used as the
all-branches-fire baseline in plan_parser_test.go.

## Simplification

- Replace the duplicated `_lookup_severity` table at `lib/foo.sh:42` and
  `lib/bar.sh:88` with a single shared helper. Reduces fan-out from 2 to 1.
- Inline the 3-line one-shot helper at `lib/baz.sh:120` — only called once.

## Staleness Fixes

- `lib/quux.sh:55` comment references `_old_fn` which was renamed in m23.
- The Watch For block in `m18.2` mentions a feature that shipped in m20 —
  remove the stale warning.

## Dead Code Removal

- `lib/foo.sh:200` declares `_FOO_TEMP` but no caller reads it.

## Naming Normalization

- Rename `_helper_x_v2` back to `_helper_x` — the v2 suffix was a migration
  artifact and the v1 was deleted in m17.

## Out of Scope

- Refactor the orchestrate retry loop — too large for this audit cycle, file
  as its own milestone.
- No items remain in the security domain.
- None

## Design Doc Observations

- DESIGN.md section "Drift handling" still references the bash drift_count
  function which moved to internal/drift/ in m25. Update the path in the
  design doc.
- ARCHITECTURE.md table of stages is missing the docs row (added m34.1).
  Update the table so new contributors see the canonical surface.
- All observations are documented in CLAUDE.md
- Updated HUMAN_ACTION_REQUIRED.md
- (route to human review)
