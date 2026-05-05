# Coder Summary

## Status: COMPLETE

## What Was Implemented
Closed all 5 open items in `.tekhton/NON_BLOCKING_LOG.md`. Two items had already
been resolved at the code level by the prior commit (105b3df) but the log was
never updated. Two items concerned GitHub Actions pinning posture, where the
existing decision (major-version tags + readonly permissions) was already
correct but under-documented. One item was about a per-run artifact that the
pipeline overwrites on every coder invocation.

Item-by-item:

1. `internal/proto/causal_v1.go:127` — `Itoa` dead code: verified removed in
   commit 105b3df. The unused `strconv` import is also gone. Updated the log
   entry to **Resolved** with a pointer to the responsible commit.
2. `internal/causal/log.go:102` — `strings.Index(string(line), key)` per-line
   string allocation: verified that `parseStageAndSeq` (now at lines 119-145)
   uses `bytes.Index` and `bytes.IndexByte` directly on the `[]byte` slice.
   No per-line allocations remain. Updated the log entry to **Resolved**.
3. `.github/workflows/go-build.yml` — `golangci/golangci-lint-action@v6` with
   `version: latest`: verified the workflow already pins `version: v1.64.5`
   at line 119. Updated the log entry to **Resolved**.
4. `.github/workflows/go-build.yml` — major-version tag pinning vs commit SHAs:
   expanded the existing header comment (lines 1-8) to spell out the decision
   framework — workflows scoped to `permissions: contents: read` with no
   external PATs use major-version tags, workflows that mint/reference a PAT
   (e.g. `brew-bump.yml`) pin to commit SHAs. The brew-bump pin
   (`actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5`) is now
   referenced explicitly so future maintainers can apply the rule
   consistently. Updated the log entry to **Resolved (intentional security
   posture)**.
5. `.tekhton/CODER_SUMMARY.md` — README missing from "Files Modified" table:
   `.tekhton/CODER_SUMMARY.md` is a per-run artifact (per ARCHITECTURE.md "File
   Ownership" table). The M01-era summary that exhibited the inconsistency has
   been overwritten by subsequent coder runs and no longer exists. The current
   coder.md and Step-5 self-check (`Consistency` bullet) require new files to
   appear under `## Files Modified` with the `(NEW)` annotation, which prevents
   recurrence. Updated the log entry to **Resolved (historical artifact)**.

## Root Cause (bugs only)
N/A — task is non-blocking note cleanup, not a bug fix.

## Files Modified
| Path | Change |
|------|--------|
| `.github/workflows/go-build.yml` | Expanded the action-pinning posture comment (lines 1-8) to make the readonly-vs-PAT decision rule explicit and reference the brew-bump SHA-pinned example. |
| `.tekhton/NON_BLOCKING_LOG.md` | Marked all 5 open items `[x]`, replaced `**Deferred:**` annotations with `**Resolved:**` and concrete justifications. |
| `.tekhton/CODER_SUMMARY.md` | (NEW per-run) This summary. |

## Docs Updated
None — docs agent verified no updates needed. The workflow comment edit is
internal documentation of an existing security decision; it does not change CI
behavior, add/remove flags, or alter any user-facing surface.

## Human Notes Status
N/A — no human notes section in this task.
