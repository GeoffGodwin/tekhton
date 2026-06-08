# Coder Summary

## Status: COMPLETE

## What Was Implemented

Mixed H2 parent + H3 subheading fixture. The `## Files` parent groups
two H3 subsections (`### Modified` and `### Created`). After m49, the
extractor must recognize the H3 BEGIN markers AND NOT terminate the
scan at the second H3 — both subsections' bullets are part of the file
list.

## Files

### Modified

- `internal/example/foo.go` — updated helper

### Created

- `internal/example/bar.go` — new helper
- `internal/example/foo_test.go` — table-driven test

## Notes

- After m49 the file list is `[foo.go, bar.go, foo_test.go]`.
- Pre-m49 the file list was `[]` because the H3 BEGIN matcher missed
  `### Modified` and the H3 END check incorrectly terminated on
  `### Created` even when the BEGIN matched on a sibling pattern.
