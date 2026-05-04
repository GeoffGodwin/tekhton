# Reviewer Report — m02 Causal Log Wedge

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `cmd/tekhton/causal.go:37` — `newCausalInitCmd` calls `causal.Open` (which scans and seeds the full log) just to ensure dirs exist, then does a separate `os.OpenFile` touch. A dedicated mkdir+touch path would be cheaper, though not incorrect. Consider a lightweight `causal.EnsureDirs(path)` helper in a future cleanup pass.
- `internal/proto/causal_v1.go:127` — `Itoa` is exported but dead code. The comment says it is for `emit.go`, but `emit.go` uses `fmt.Sprintf` instead. Remove or use in a future cleanup pass.
- `internal/causal/log.go:102` — `strings.Index(string(line), key)` allocates a string per seed scan line. `bytes.Index(line, []byte(key))` avoids this. At 2000 events the cost is negligible; clean-up candidate only.
- `cmd/tekhton/causal.go` — `--stage` and `--type` on the emit subcommand are not marked `cobra.MarkFlagRequired`. Validation falls through to `causal.Emit`, which returns an internal error string rather than Cobra's standard usage output. Functional but inconsistent with Cobra conventions.

## Coverage Gaps
- `causal status` subcommand has no bash test in `tests/test_causal_log.sh`. The Go-side `lastEventID` helper is exercised indirectly through `_last_event_id`, but a direct `tekhton causal status` invocation test would be cleaner once the binary is always available.
- `newCausalInitCmd` has no Go unit test. Its logic is thin (Open + touch), low risk, but a round-trip test in `cmd/tekhton/` would complete the CLI surface coverage.

## ACP Verdicts
- ACP: Bash fallback inside `lib/causality.sh` — ACCEPT — `_json_escape` serves 20+ callers that predate m02; moving it to `lib/common.sh` is the correct canonical home, and the transitional fallback is necessary until the Go binary is universally installed. The parity gate (`scripts/causal-parity-check.sh`) proves byte-level format compatibility.
- ACP: `tekhton causal init` does not truncate — ACCEPT — Resume-friendly no-op semantics are the only correct choice; truncating on init would destroy resumed-run events. The milestone AC #1 wording is what is wrong, not the implementation. The design observation is correctly logged for a future doc cleanup.

## Drift Observations
- `lib/crawler.sh` — defines `_json_escape` with a body byte-identical to `lib/common.sh`. After m02 this is a shadowing duplicate: `common.sh` is always sourced first, so `crawler.sh`'s definition is dead. Coder already noted it as out of scope; cleanup candidate for the next drift-sweep pass.
- `internal/proto/causal_v1.go:127` — `Itoa` is exported dead code (see Non-Blocking Notes above). Consolidate or remove in a future cleanup pass.
