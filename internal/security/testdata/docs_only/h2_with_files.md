# Coder Summary

## Status: COMPLETE

## What Was Implemented

Canonical H2 fixture used to lock in that the historical extractor path
still works. The Files Modified section contains a Go file, so
`IsDocsOnly` must return false.

## Files Modified

- `internal/example/foo.go` — added helper
- `docs/README.md` — updated reference

## Watch For

Regression: this is the H2 happy path. If a future change breaks it,
the historical extractor contract has regressed.
