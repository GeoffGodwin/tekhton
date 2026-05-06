<!-- milestone-meta
id: "17"
status: "todo"
-->

# m17 — Error Taxonomy Wedge

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 4 — sixth wedge, closing the first batch. The bash error-classification engine (`lib/errors.sh` + `lib/errors_helpers.sh` + `lib/error_patterns*.sh`, ~800 LOC total) categorizes failures, suggests recoveries, and routes them to `HUMAN_ACTION_REQUIRED.md`. m07 introduced `internal/supervisor.AgentError`; m12 added recovery dispatch in `internal/orchestrate`; m13/m14/m15/m16 each declared their own typed errors. m17 unifies these into `internal/errors`. |
| **Gap** | Errors live in five places: `internal/supervisor` (agent errors), `internal/state` (legacy/corrupt), `internal/orchestrate` (recovery class), `internal/dag` (validation), `internal/config` (validation), plus the bash side's pattern-based regex classifier. No single `errors.Is(err, …)` lookup works across all of them. |
| **m17 fills** | (1) `internal/errors` package consolidating cross-cutting error types: `ErrTransient`, `ErrFatal`, `ErrUserActionRequired`, `ErrConfigInvalid`, etc. Subsystem-specific errors stay in their packages but wrap the common types. (2) `tekhton diagnose classify <log>` subcommand — Go-native error pattern classifier replacing `lib/error_patterns.sh::classify_build_errors_with_stats`. (3) `internal/errors/patterns.go` carries the regex registry that `lib/error_patterns.sh` does today. (4) Bash `errors.sh` shrinks; pattern files delete. |
| **Depends on** | m12, m13, m14, m15, m16 |
| **Files changed** | `internal/errors/` (new), `cmd/tekhton/diagnose.go` (new), `internal/{supervisor,state,orchestrate,dag,config}/errors.go` (modify — wrap common types), `lib/errors.sh` / `lib/errors_helpers.sh` / `lib/error_patterns*.sh` (delete or shrink), `scripts/error-classify-parity-check.sh` (new) |
| **Stability after this milestone** | Stable. Phase 4 first batch closed. Next batch (dashboard, TUI, stages) gets its own design pass. |
| **Dogfooding stance** | Cutover within milestone. |

---

## Design

### Goal 1 — Common error sentinels

```go
package errors

var (
    ErrTransient          = errors.New("transient")
    ErrFatal              = errors.New("fatal")
    ErrUserActionRequired = errors.New("user_action_required")
    ErrConfigInvalid      = errors.New("config_invalid")
    ErrUpstreamLimit      = errors.New("upstream_limit")
)
```

Subsystem errors wrap these. For example `supervisor.AgentError` (m07)
gets an `Is(target error)` method that matches `ErrTransient` when
`Transient: true`. `errors.Is(supErr, errors.ErrTransient)` works without
the orchestrate loop knowing about supervisor internals.

### Goal 2 — Pattern classifier port

`lib/error_patterns.sh::classify_build_errors_with_stats` and the M127
confidence-based mixed-log classifier (`lib/error_patterns_classify.sh`)
port to `internal/errors/patterns.go`. The pattern registry is data, not
logic — moves cleanly. The classifier output (`code_dominant` /
`noncode_dominant` / `mixed_uncertain` / `unknown_only`) is the M128
contract; preserve byte-for-byte.

### Goal 3 — `tekhton diagnose classify`

```
tekhton diagnose classify --input BUILD_ERRORS.md
```

Reads a build log, classifies, prints the routing decision + stats.
Replaces the M127 inline classifier in `stages/coder_buildfix.sh`. The
m12 orchestrate loop and m14 dag both consume it via in-process calls.

### Goal 4 — Bash side

`lib/errors.sh` becomes a thin shim — `report_error`, `report_retry`
helpers stay (they emit to stderr, no logic). Pattern files
(`lib/error_patterns.sh`, `_classify.sh`, `_remediation.sh`) delete after
the M127/M128 contracts are verified by the parity script.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/errors/` | Create | Common sentinels + pattern classifier. ~400-500 LOC. |
| `cmd/tekhton/diagnose.go` | Create | `diagnose classify` subcommand. ~80 LOC. |
| `internal/supervisor/errors.go` | Modify | `AgentError.Is` matches common sentinels. |
| `internal/state/snapshot.go` | Modify | `ErrCorrupt`, `ErrLegacyFormat` wrap `errors.ErrFatal`. |
| `internal/orchestrate/recovery.go` | Modify | Recovery dispatch consumes common sentinels. |
| `internal/dag/validate.go` | Modify | `ValidationError` wraps `errors.ErrConfigInvalid`. |
| `internal/config/validate.go` | Modify | Same. |
| `lib/errors.sh` | Modify | Shrink to ~80 lines (report helpers only). |
| `lib/errors_helpers.sh` | Delete | Recovery suggestions move to Go pattern registry. |
| `lib/error_patterns*.sh` | Delete | Pattern registry + classifier in Go. |
| `scripts/error-classify-parity-check.sh` | Create | M127 / M128 byte-for-byte parity. ~150 LOC. |

---

## Acceptance Criteria

- [ ] `tekhton diagnose classify --input <fixture>.log` produces output matching `bash -c 'source lib/error_patterns_classify.sh; classify_routing_decision'` for every fixture in `tests/fixtures/error_classification/`.
- [ ] `errors.Is(supErr, errors.ErrTransient)` returns true for every supervisor error with `Transient: true`.
- [ ] `errors.Is(stateErr, errors.ErrFatal)` returns true for `state.ErrCorrupt` and `state.ErrLegacyFormat`.
- [ ] `errors.Is(dagErr, errors.ErrConfigInvalid)` returns true for `dag.ValidationError`.
- [ ] `lib/errors.sh` is ≤ 100 lines.
- [ ] `git ls-files lib/errors_helpers.sh lib/error_patterns*.sh` returns no files.
- [ ] `internal/errors` coverage ≥ 80%.
- [ ] `scripts/error-classify-parity-check.sh` exits 0 against the M127 / M128 fixture set.
- [ ] `bash tests/run_tests.sh` passes; error-classification tests adapted.

## Watch For

- **M127 / M128 contracts are load-bearing.** Confidence thresholds, category names, and the four routing tokens are the public contract `stages/coder_buildfix.sh` consumes. Byte-for-byte parity required.
- **Don't sprawl the sentinel set.** Five common errors is plenty; resist the urge to add `ErrUpstreamRateLimit`, `ErrUpstreamOOM`, etc. — those stay subsystem-specific (in `internal/supervisor`).
- **Pattern registry is data.** Keep it in a single Go file (`patterns.go`) with one struct per pattern. A future YAML/JSON externalization is a Phase 5 candidate, not m17.
- **Cross-package error wrapping requires `Unwrap` + `Is`.** Test that `errors.Is` and `errors.As` both work for wrapped errors. Easy to break with subtle pointer-vs-value receiver mistakes.

## Seeds Forward

- **Phase 4 second batch:** dashboard emitters, TUI status writer, stage-port preparation. Designed after m17 lands.
- **Diagnose stage port (Phase 5):** `lib/diagnose.sh` and `lib/diagnose_rules*.sh` consume the unified error taxonomy. `tekhton diagnose run` becomes the full CLI surface.
- **V5 multi-provider error mapping:** providers will surface their own error types; the common sentinels (`ErrTransient`, `ErrUpstreamLimit`) become the lingua franca the dispatch layer routes on. m17 establishes the seam.
- **Phase 5 `lib/error_patterns_remediation.sh`:** the auto-remediation engine consumes the pattern registry; ports as a sibling package once the registry is Go-native.
