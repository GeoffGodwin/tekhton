# Reviewer Report — m32.1 Diagnose Engine (Cycle 2)

## Verdict
APPROVED_WITH_NOTES

Both cycle-1 blockers are confirmed fixed. The rework introduced no regressions.

**Blocker 1 — `doubleQuotedRe` (engine.go:229-231):** FIXED.
`grep doubleQuotedRe internal/diagnose/` returns no matches. The package-level
dead variable is gone.

**Blocker 2 — `jsonString()` method (engine.go:389-397):** FIXED.
`grep jsonString internal/diagnose/` returns no matches. The unexported dead
method is gone, and `encoding/json` is absent from the import block (lines
15–26) — the orphaned import was cleaned up correctly.

`engine.go` is now 381 lines, imports are all consumed, and `go test ./...`
was reported passing by the coder.

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `engine.go:306-308`: `extractKVLine` compiles two regexes via `regexp.MustCompile` on every call; `parseCauseBlock` calls it per line of each cause block. Carry forward from cycle 1 — promote to package-level variables (matching the style of `classificationRe`/`consecutiveCountRe` in `helpers.go`) to avoid repeated compilation on the per-line path.
- `engine.go:213`: `c.CauseChain = ""` stub has no comment tying it to the missing `cause_chain_summary` port. Carry forward from cycle 1 — a `// TODO(m32.2): extract cause chain from c.CausalEvents via causality port` comment would make the gap self-documenting for the next milestone author.
- `bash_rule_adapter.go`: `flattenLogTails` iterates over a `map[string]string` with non-deterministic key order. Carry forward from cycle 1 — sort keys (mirroring `CollectAgentLogTails`'s `sort.Strings`) for deterministic output.
- Fixture `expected/` directories contain `verdict.txt` stubs rather than the milestone-specified `DIAGNOSIS.md` + `diagnosis.js` shapes. Appropriate m32.1 scope reduction; m32.3 authors must add those files to complete the parity gates.
- `make dogfood` pre-existing failure (`tests/test_stage_env_setu.sh` — `lib/gates.sh` deleted in m31.1) is correctly identified as out of scope. Should be resolved as a m31-arc follow-up before m32.3 bumps VERSION.

## Coverage Gaps
- `parseCauseBlock`, `extractJSONString`, `extractJSONInt` (private readers in `engine.go`) are exercised only transitively through `TestReadContext_FailureContextPopulatesClassification`. Direct table-driven tests covering malformed JSON, missing cause blocks, and multi-value nested objects would guard correctness without a full ReadContext round-trip.
- No test drives `tekhton diagnose run` CLI with a populated fixture; existing CLI tests only cover the no-state path and `--help`. A test materializing `max-turns-coder` through `cmd.Execute()` would close the gap between the engine integration test and the CLI smoke test.

## ACP Verdicts

None — no Architecture Change Proposals in CODER_SUMMARY.md.

## Drift Observations
- `internal/diagnose/types.go`: `CausalEvents` and `ErrorEvents` fields are `string` (newline-joined) while the milestone design spec shows `[]string`. Works correctly with the bash adapter and the `grepLines`/`countLinesMatchingBoth` helpers, but m32.2 Go-native rules will need `strings.Split`. A field comment noting "newline-joined; split on \\n to iterate events" would prevent m32.2 confusion. Carry forward from cycle 1.
- `engine.go` `ReadContext`: the `c.CauseChain = ""` stub has no inline comment tying it to the missing `cause_chain_summary` port. Carry forward from cycle 1.
