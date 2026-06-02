<!-- milestone-meta
id: "35"
status: "split"
-->

# m35 — Security Stage Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 V4 sprint — second stage-port milestone in the `stages/*.sh` → `internal/stages/<name>/` arc. M34 established the Go-adapter pattern (per-stage Go package, `RunStage(ctx, req proto.StageRequest) (proto.StageResult, error)` entry point, `StageDef.GoImpl` field, `internal/stagerunner.GoAdapter` dispatch). M35 applies that pattern to the security stage — the second user-facing stage in the canonical pipeline order (intake → coder → **security** → review → tester → cleanup → docs). The security stage is the pipeline's first hard-stop gate: a HIGH-severity unfixable finding can halt the run or escalate to `HUMAN_ACTION_REQUIRED.md`. Until this port lands, every security review still pays the bash sourcing cost (`stages/security.sh` + `lib/security_helpers.sh` + the full `DefaultLibHelpers` block), and the severity-classification logic that decides whether to block lives in a bash subshell pipeline that exec's `grep`/`tr`/`cut` per finding. |
| **Gap** | `stages/security.sh` (167 LOC) + `lib/security_helpers.sh` (240 LOC) = 407 LOC of bash that run on every non-docs-only pipeline. The stage renders two prompts (`security_scan`, `security_rework`), invokes the security agent in a scan/rework loop (capped by `SECURITY_MAX_REWORK_CYCLES`, default 2), parses `${SECURITY_REPORT_FILE}` (`.tekhton/SECURITY_REPORT.md` default) for `- [SEVERITY] [fixable:yes\|no\|unknown] description` rows, ranks findings against `SECURITY_BLOCK_SEVERITY` (default HIGH; CRITICAL>HIGH>MEDIUM>LOW), routes blocking-fixable items to a rework agent call, escalates unfixable blocking items via `SECURITY_UNFIXABLE_POLICY` (`escalate` → `tekhton drift human-action append`; `halt` → write pipeline state and exit 1; `waiver` → log and continue), and emits non-blocking notes to `${SECURITY_NOTES_FILE}`. The classification predicate `_severity_meets_threshold` is hot — it runs once per finding per cycle, currently via a bash associative-array lookup. The Go runtime already has all the seams this port needs: `internal/prompt` (m15) renders templates, `internal/supervisor` (m05-m10) invokes the agent, `internal/drift/artifacts.go::HumanAction` (m25) appends to `HUMAN_ACTION_REQUIRED.md`, `internal/proto.StageRequestV1`/`StageResultV1` (m18) types the envelope, and the M34 `GoAdapter` dispatches Go-native RunStage funcs. The only thing missing is the Go-native security package itself. |
| **m35 fills** | The full security stage ports to `internal/security/` (helper logic) + `internal/stages/security/` (stage entry point) across three sequenced child milestones, each independently dogfood-able and shipping a parity gate against the bash baseline. **M35.1 — Security helpers port:** `internal/security/{severity.go, findings.go, escalation.go}`, pure-Go severity classifier + finding parser + HUMAN_ACTION_REQUIRED.md escalation writer (delegating to `internal/drift.HumanAction`). Unit-test coverage ≥80%. Bash stage continues to work via a one-line shim in `lib/security_helpers.sh` that execs `tekhton security <sub>` — same shim shape as the m25 drift-cleanup compatibility layer. **M35.2 — Security stage port:** `internal/stages/security/run.go` with `RunStage(ctx, req)` registered in `DefaultStageDefs` via the M34 `GoImpl` field. Stage renders `security_scan` + `security_rework` via `internal/prompt`, invokes the agent via `internal/supervisor`, calls into M35.1's helpers, writes the `StageResultV1`. `stages/security.sh` deletes; `lib/security_helpers.sh` shim deletes (the Go path no longer needs it). **M35.3 — Integration cleanup:** wedge-audit ban on re-introduction, parity-test scenarios, CHANGELOG entry, residual-caller scan, `VERSION` bump. All three preserve the operator-facing behavior byte-for-byte: `SECURITY_AGENT_ENABLED=false` skips the stage; the prompt template path stays `prompts/security_scan.prompt.md` + `prompts/security_rework.prompt.md` (specialist template referenced by name only); the `[security]` log prefix is preserved; the rework-cycle counter format is preserved. |
| **Depends on** | m34 |
| **Files changed** | `internal/security/` (new package, ~350 Go LOC across severity + findings + escalation), `internal/stages/security/` (new package, ~250 Go LOC across run.go + helpers, follows M34 pattern), `internal/stagerunner/helpers.go` (modify — wire `StageDef.GoImpl` for security via the M34 field), `cmd/tekhton/security.go` (modify or create — `tekhton security parse-findings` + `tekhton security classify` subcommands the bash shim uses during M35.1), `stages/security.sh` (delete in m35.2), `lib/security_helpers.sh` (delete in m35.2 — replaced by `tekhton security` shim during M35.1, retired in M35.2), `scripts/wedge-audit.sh` (modify in m35.3 — forbid re-introduction), parity test `tests/test_security_parity.sh` (new in m35.3), `docs/v4-phase5-stub.md` (modify in m35.3 — mark security stage done in the per-stage matrix), `CHANGELOG.md` (modify in m35.3 — close-out entry). |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m15 | Prompt-engine wedge — `internal/prompt` renders templates Go-native. The security stage's M35.2 RunStage calls `prompt.Render("security_scan", env)` instead of bash `render_prompt`. |
| m18 | Stage-envelope contract — `proto.StageRequestV1` / `StageResultV1`. The security stage's RunStage signature consumes/produces these envelopes. |
| m25 | Drift port — `internal/drift/artifacts.go::HumanAction.Append` is the canonical Go writer for `HUMAN_ACTION_REQUIRED.md`. M35.1's escalation routes through it; **no new escalation path is invented**. |
| m34 | Stage-port pattern established — `internal/stages/<name>/` package layout, `RunStage(ctx, req)` signature, `StageDef.GoImpl` field, `stagerunner.GoAdapter` dispatch. M35 inherits the pattern verbatim. |
| **m35** | **Security stage + helpers ported to Go; bash files delete; severity classification + finding parsing + escalation routed through `internal/drift` parity-tested byte-for-byte.** |

---

## Design

### Sequencing note

M35 is smaller than M32 (407 LOC vs 1,846 LOC) but the three-child split is still warranted: the helpers (M35.1) have rich classification logic that benefits from independent unit-test coverage before the stage wraps them, and the cleanup work (M35.3) is best isolated so the wedge-audit + parity gate land on a quiescent tree. M34 already proved the stage-port pattern survives a one-shot port for a small stage; M35 takes the same pattern but splits it three ways so the helpers ship before the stage that calls them — a smaller blast radius per child.

The order is:

1. **M35.1 — Helpers first.** `internal/security/` lands with full unit tests. The bash stage continues to work because `lib/security_helpers.sh` becomes a thin shim that execs `tekhton security <sub>` for the four functions it currently exports (`_parse_security_findings`, `_severity_meets_threshold`, `_build_fixable_block`, `_build_unfixable_block`). The shim approach is cleaner than keeping bash logic intact because it forces the parity surface through the Go path at M35.1 close — by the time M35.2 starts, the Go helpers have been dogfooded under the still-bash stage.
2. **M35.2 — Stage second.** `internal/stages/security/run.go` lands. `stages/security.sh` deletes. `lib/security_helpers.sh` shim deletes (the Go stage calls the Go helpers directly — no shim needed once bash callers retire).
3. **M35.3 — Cleanup last.** wedge-audit ban, parity gate against pre-M35 baselines, CHANGELOG entry, residual scan.

### Goal 1 — `internal/security/` package shape (M35.1)

The Go-side package layout mirrors the bash partition so a reader who knows the bash can navigate the Go:

```
internal/security/
├── severity.go              # M35.1 — Severity type, Rank table, MeetsThreshold predicate
├── severity_test.go         # M35.1 — ranking + threshold table tests
├── findings.go              # M35.1 — Finding type, ParseReport, IsDocsOnly fast-path
├── findings_test.go         # M35.1 — parser table tests + golden-file replay
├── escalation.go            # M35.1 — Escalate routes to internal/drift.HumanAction.Append
├── escalation_test.go       # M35.1 — policy-branch tests (escalate / halt / waiver / unknown)
├── blocks.go                # M35.1 — BuildFixableBlock / BuildUnfixableBlock / BuildNotesBlock
├── blocks_test.go           # M35.1
└── testdata/
    ├── reports/             # Synthetic SECURITY_REPORT.md fixtures (per-severity, per-fixable combinations)
    └── baselines/           # Pre-M35 bash-emitted block outputs for parity replay
```

Public API sketch:

```go
package security

type Severity string  // "CRITICAL" | "HIGH" | "MEDIUM" | "LOW"

// Rank returns the numeric rank for ordering. CRITICAL=4, HIGH=3, MEDIUM=2, LOW=1.
// Unknown returns 0 — matches the bash `severity_rank[$severity]:-0` fallback.
func Rank(s Severity) int

// MeetsThreshold returns true when s >= threshold. Mirrors _severity_meets_threshold.
func MeetsThreshold(s, threshold Severity) bool

type Finding struct {
    Severity    Severity
    Fixable     string  // "yes" | "no" | "unknown"
    Description string
}

// ParseReport reads the SECURITY_REPORT.md at path and returns its findings.
// Mirrors _parse_security_findings: scans for `## Findings`, collects `- [SEVERITY] [fixable:V] desc`
// rows until the next `## ` heading. Returns (nil, nil) when file missing — bash semantics.
func ParseReport(path string) ([]Finding, error)

// IsDocsOnly reports whether every file in the coder summary is docs/config/asset.
// Mirrors _security_is_docs_only — the fast-path skip predicate.
func IsDocsOnly(summaryPath string) (bool, error)

// BuildFixableBlock returns the bash-format string for findings >= threshold AND fixable==yes.
func BuildFixableBlock(fs []Finding, threshold Severity) string

// BuildUnfixableBlock returns findings >= threshold AND fixable!=yes.
func BuildUnfixableBlock(fs []Finding, threshold Severity) string

// BuildNotesBlock returns findings < threshold (the non-blocking notes).
func BuildNotesBlock(fs []Finding, threshold Severity) string

// Escalator wraps a drift.HumanAction for escalation. NewEscalator returns one
// bound to projectDir/.tekhton/HUMAN_ACTION_REQUIRED.md.
type Escalator struct {
    HumanAction *drift.HumanAction
    State       *state.Store  // optional — only used by Policy="halt"
}

// HandleUnfixable applies SECURITY_UNFIXABLE_POLICY. Returns (continue=true, nil)
// for escalate/waiver/unknown branches; returns (false, nil) for halt (caller
// must propagate as a block verdict).
func (e *Escalator) HandleUnfixable(policy string, unfixableBlock, task string) (cont bool, err error)
```

`internal/drift.HumanAction` (m25) exposes `Append(source, description string) error` and `EnsureFile() error` — `Escalator.HandleUnfixable` calls `e.HumanAction.EnsureFile()` then `e.HumanAction.Append("security", "Unfixable security findings require human review:\n"+unfixableBlock)`. No new path is invented.

### Goal 2 — `internal/stages/security/` package shape (M35.2)

Following the M34 pattern verbatim:

```
internal/stages/security/
├── run.go                   # M35.2 — RunStage(ctx, req) Go entry point
├── run_test.go              # M35.2 — integration tests against fake-agent supervisor
├── scan.go                  # M35.2 — invokeScanAgent helper (prompt render + supervisor.Run)
├── rework.go                # M35.2 — invokeReworkAgent helper + cycle counter
├── docs_only.go             # M35.2 — thin wrapper around security.IsDocsOnly + log emit
└── testdata/
    ├── fake_agent.sh        # Test supervisor binary
    └── fixtures/            # End-to-end stage fixtures (no findings / fixable / unfixable-halt / unfixable-escalate)
```

Public API:

```go
package security  // pkg name "security" inside internal/stages/security/

import (
    "context"
    sec "github.com/geoffgodwin/tekhton/internal/security"
    "github.com/geoffgodwin/tekhton/internal/proto"
)

// RunStage is the M34-pattern entry point. The stagerunner GoAdapter calls
// this when DefaultStageDefs[StageSecurity].GoImpl is non-nil.
func RunStage(ctx context.Context, req proto.StageRequestV1) (proto.StageResultV1, error)
```

The RunStage flow mirrors `run_stage_security` line-for-line:

1. Read config from `req.EnvOverrides` (with env-var fallback): `SECURITY_AGENT_ENABLED`, `SKIP_SECURITY`, `SECURITY_MAX_REWORK_CYCLES`, `SECURITY_MAX_TURNS`, `SECURITY_MIN_TURNS`, `SECURITY_MAX_TURNS_CAP`, `SECURITY_BLOCK_SEVERITY`, `SECURITY_UNFIXABLE_POLICY`, `SECURITY_REPORT_FILE`, `SECURITY_NOTES_FILE`, `MILESTONE_MODE`, `MILESTONE_SECURITY_MAX_TURNS`.
2. **Skip checks** (in order, matching bash): `SECURITY_AGENT_ENABLED != "true"` → return Skip; `SKIP_SECURITY == "true"` → return Skip; `sec.IsDocsOnly(coderSummary)` → return Skip.
3. **Scan/rework loop** (capped by `max_rework`):
   - Compute `security_turns` with the clamp (`SECURITY_MIN_TURNS` ≤ value ≤ `SECURITY_MAX_TURNS_CAP`; doubled in `MILESTONE_MODE`).
   - Read previous `SECURITY_REPORT.md` content (if any) into `SECURITY_REPORT_CONTENT` env.
   - Render `security_scan` via `prompt.Render`.
   - Call `supervisor.Run` with role "Security (scan)".
   - Parse findings via `sec.ParseReport`.
   - If no findings → break loop, return Pass.
   - Build fixable/unfixable/notes blocks via `sec.BuildFixableBlock` etc.
   - Write notes file (matching bash `_write_security_notes` byte layout — see Goal 5).
   - If unfixable: call `escalator.HandleUnfixable(policy, unfixableBlock, task)`. If returns `cont=false` → emit `StageResultV1{Verdict: VerdictBlock, ExitReason: "security_halt", HumanAction: true}` and return.
   - If fixable AND `cycle < max_rework`: render `security_rework` (with `SECURITY_FIXABLE_BLOCK` env), call supervisor, run build gate via `gates.RunBuildGate` (m31), continue loop if gate passes.
4. **Emit verdict**:
   - Findings present, no blockers, no rework → `Verdict: VerdictPass`.
   - Unfixable + halt policy → `Verdict: VerdictBlock`, `HumanAction: true`.
   - Unfixable + escalate/waiver → `Verdict: VerdictPass`, `HumanAction: (escalate ? true : false)`.

### Goal 3 — `DefaultStageDefs` rewire (M35.2, M34 pattern)

The current `DefaultStageDefs[proto.StageSecurity]` (helpers.go line 163-166) sources `stages/security.sh` + `lib/security_helpers.sh`. M34 introduced `StageDef.GoImpl` per the inherited pattern. M35.2 sets it:

```go
// internal/stagerunner/helpers.go — modified in M35.2
proto.StageSecurity: {
    GoImpl:  securitystage.RunStage,  // M35.2
    // Script + Helpers fields removed: Go path owns dispatch now.
},
```

Bash file deletions happen in the same M35.2 commit. The `lib/security_helpers.sh` shim that landed in M35.1 also retires here because no bash caller remains — the security stage was the only consumer.

### Goal 4 — Bash-shim approach for M35.1 transition

During M35.1 the bash stage (`stages/security.sh`) still exists, and it still sources `lib/security_helpers.sh`. The helpers move to Go but the bash interface is preserved by rewriting `lib/security_helpers.sh` as a thin shim:

```bash
# lib/security_helpers.sh — M35.1 shim (~40 LOC, replaces the 240 LOC original)
# Each helper function execs into `tekhton security <sub>` and reads stdout.

_parse_security_findings() {
    local report_file="${1:-${SECURITY_REPORT_FILE:-.tekhton/SECURITY_REPORT.md}}"
    _SEC_SEVERITIES=() _SEC_FIXABLES=() _SEC_DESCRIPTIONS=()
    while IFS=$'\t' read -r sev fix desc; do
        [[ -z "$sev" ]] && continue
        _SEC_SEVERITIES+=("$sev")
        _SEC_FIXABLES+=("$fix")
        _SEC_DESCRIPTIONS+=("$desc")
    done < <("${TEKHTON_BIN:-tekhton}" security parse-findings --report "$report_file" --format tsv 2>/dev/null)
    [[ ${#_SEC_SEVERITIES[@]} -gt 0 ]]
}

_severity_meets_threshold() {
    "${TEKHTON_BIN:-tekhton}" security meets-threshold --severity "$1" --threshold "$2"
}

# ... build-fixable-block, build-unfixable-block, build-notes-block, is-docs-only,
# handle-unfixable similar exec wrappers.
```

`cmd/tekhton/security.go` (created in M35.1) wires `tekhton security parse-findings`, `tekhton security meets-threshold`, `tekhton security build-block`, `tekhton security is-docs-only`, `tekhton security handle-unfixable`. The TSV output for `parse-findings` is a parity-stable wire format that the bash shim reads back into the legacy arrays. This keeps the bash stage operationally green through the M35.1 → M35.2 transition.

After M35.2 lands, the shim deletes (no bash callers remain) — but `cmd/tekhton/security.go` stays as an operator-facing CLI surface for debugging (consistent with `tekhton diagnose classify` retention pattern from m17/m32).

### Goal 5 — Byte-for-byte parity surfaces

These outputs are operator-visible and must match bash byte-for-byte (after timestamp normalization). The parity gate in M35.3 enforces this; each is called out here so the M35.1/M35.2 implementer doesn't drift:

1. **`SECURITY_NOTES_FILE` content** — the `_write_security_notes` heredoc emits:
   ```
   # Security Notes

   Generated: YYYY-MM-DD HH:MM:SS

   ## Non-Blocking Findings (MEDIUM/LOW)
   - [MEDIUM] desc...
   - [LOW] desc...

   ## Waivered Findings    (only when policy=waiver and unfixable_block non-empty)
   - [HIGH] desc...
   ```
   The Go port reproduces this layout including the blank-line spacing and the conditional `## Waivered Findings` section.
2. **`HUMAN_ACTION_REQUIRED.md` escalation row** — the bash version invokes `tekhton drift human-action append --source security --description "Unfixable security findings require human review:\n${unfixable_block}"`. The Go path calls `drift.HumanAction.Append("security", desc)` with the same `desc` shape. Description prefix is exactly `Unfixable security findings require human review:\n` — operator tooling greps for this string.
3. **`[security]` log prefix** — every log line emitted by the Go stage starts with `[security] ` (mirroring bash `log "[security] ..."`). The parity gate diffs stdout.
4. **`SECURITY_FINDINGS_BLOCK` / `SECURITY_FIXES_BLOCK` env exports** — bash exports these for downstream stages (review, finalize). The Go stage emits them via `StageResultV1.EnvOverrides`-equivalent or writes them to `${TEKHTON_HOME}/.tekhton/SECURITY_OUTPUTS.env` if the stage envelope doesn't carry exports forward. (M34 should have established this seam — confirm at M35.2 design pass.)
5. **Severity-classification thresholds** — `CRITICAL=4, HIGH=3, MEDIUM=2, LOW=1, unknown=0`. The bash predicate is `[[ "$sev_val" -ge "$thr_val" ]]`. The Go predicate must be `Rank(s) >= Rank(threshold)` — same semantics, including the unknown=0 fallback that lets an unparseable severity always fall below any defined threshold.

### Goal 6 — Test strategy

- **Unit tests (M35.1):** Per-function tables in `severity_test.go`, `findings_test.go`, `escalation_test.go`, `blocks_test.go`. Coverage ≥80% gate at the package level.
- **Golden-file parity (M35.1):** Capture pre-M35 bash outputs for 6 synthetic `SECURITY_REPORT.md` fixtures (no findings, all-LOW, mixed-fixable, all-CRITICAL-unfixable, malformed-severity-fallback, empty `## Findings` section). Each fixture's Go output (`parse-findings --format tsv`, `build-block`, etc.) diffs byte-identical.
- **Stage-level parity (M35.2):** End-to-end stage invocations against a fake supervisor binary that emits canned `SECURITY_REPORT.md` files. Three scenarios at minimum: docs-only-skip, agent-disabled-skip, scan→findings→rework→pass.
- **Integration parity (M35.3):** `tests/test_security_parity.sh` runs the Go stage against three fixtures captured from the pre-M35 bash baseline and asserts byte-identical `DIAGNOSIS`-style output. Wires into `make dogfood`.

### Goal 7 — `cmd/tekhton/security.go` CLI surface

Created in M35.1 to back the shim; retained after M35.2 for operator debugging (matches the m17 `tekhton diagnose classify` precedent):

```
tekhton security parse-findings --report PATH [--format tsv|json]   # parse SECURITY_REPORT.md
tekhton security meets-threshold --severity SEV --threshold THR     # exit 0 if SEV >= THR
tekhton security build-block --report PATH --kind fixable|unfixable|notes --threshold THR
tekhton security is-docs-only --summary PATH                        # exit 0 if all files are docs/config/asset
tekhton security handle-unfixable --policy POLICY --block STR --task STR --project-dir DIR
```

All five subcommands stay `Hidden: true` in Cobra — they're shim-only, not advertised. The exception is `parse-findings`, which is useful enough as an operator tool to consider un-hiding (decide at M35.1 review).

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `.claude/milestones/m35.1-security-helpers-port.md` | Create | Child milestone — Go-native severity classifier + finding parser + escalation; bash shim during transition. |
| `.claude/milestones/m35.2-security-stage-port.md` | Create | Child milestone — `internal/stages/security/RunStage` registered in `DefaultStageDefs.GoImpl`; bash stage + shim deleted. |
| `.claude/milestones/m35.3-integration-cleanup.md` | Create | Child milestone — wedge-audit ban, parity gate, CHANGELOG, residual-caller scan, VERSION bump. |
| `.claude/milestones/MANIFEST.cfg` | Modify (by human at review pass) | Add four rows for m35 / m35.1 / m35.2 / m35.3. Not authored by this milestone — the human owns it. |

---

## Acceptance Criteria

- [ ] All three child milestone files (`m35.1-security-helpers-port.md`, `m35.2-security-stage-port.md`, `m35.3-integration-cleanup.md`) exist under `.claude/milestones/` and pass the m85 acceptance-criteria linter.
- [ ] Each child's `Depends on` row in `## Overview` matches the corresponding `depends_on` column in `MANIFEST.cfg` (m35.1 depends on m34.2; m35.2 depends on m35.1; m35.3 depends on m35.2).
- [ ] The parent's status in `MANIFEST.cfg` is `split` (not `todo` / `in_progress` / `done`); the runtime treats split-status parents as descriptive-only and does not schedule them for execution.
- [ ] No bash files under `stages/security.sh` or `lib/security_helpers.sh` are deleted by this parent milestone — deletions live in M35.2.
- [ ] No `VERSION` bump happens at the parent level — the bump lives in M35.3 on close.
- [ ] `internal/security/` and `internal/stages/security/` do not yet exist on disk when this parent is filed; the children create them.
- [ ] The parent file references M34 as the established pattern source for stage-port architecture and does not redesign the `GoImpl` / `RunStage` / `GoAdapter` mechanics.

## Watch For

- **Severity-classification thresholds must match bash output byte-for-byte.** CRITICAL=4, HIGH=3, MEDIUM=2, LOW=1, unknown=0. The unknown-fallback is operator-relevant: an unparseable severity must never block. The parity gate enforces this — do not refactor the ranking table into a slice-index lookup that would change unknown-severity behavior.
- **`SECURITY_AGENT_ENABLED=false` must skip the stage entirely.** This is the kill-switch operators use when the security agent's quota is exhausted or the model is down. The Go stage's RunStage must return a `Skip` verdict (not Pass, not error) the moment this env reads `!= "true"` — same as bash line 23-26. A Pass verdict here would drop the operator's safety net silently.
- **The prompt template path stays the same — no template content changes.** `prompts/security_scan.prompt.md` and `prompts/security_rework.prompt.md` are operator-edited templates; the rendering caller moves from bash to Go but the templates are out of scope. `prompts/specialist_security.prompt.md` is referenced by name from the security_scan template (or invoked separately by the agent) and likewise stays put.
- **HUMAN_ACTION_REQUIRED.md escalation must use `internal/drift/artifacts.go::HumanAction.Append`.** Do NOT invent a new escalation path. The m25 drift package is the universal writer for this file; M36 (architect + intake) will also route writes through it. Inventing a sidecar writer here would force M36 to either duplicate or migrate — both are wasted work.
- **The bash shim during M35.1 must NOT introduce a regression.** The shim execs `tekhton security <sub>` once per call; the bash stage calls `_parse_security_findings` once per cycle and `_severity_meets_threshold` once per finding per cycle. Worst case (10 findings, 2 rework cycles) = 22 subprocess spawns. At ~20ms each that's ~440ms added to the stage. Acceptable, but document the transition tax in `docs/go-migration.md`. The tax retires entirely at M35.2 when the Go stage calls Go helpers in-process.
- **`SECURITY_UNFIXABLE_POLICY` defaults to `escalate`, not `halt`.** The bash default at `lib/security_helpers.sh:178` is `escalate`. An implementer who reads the `halt` branch first might assume halt is default — it is not. The Go port must preserve `escalate` as the default for the `policy = req.EnvOverrides["SECURITY_UNFIXABLE_POLICY"] || "escalate"` resolution.
- **The rework loop's build-gate call after a rework cycle is load-bearing.** Bash line 138-141: if the build gate fails post-rework, the loop breaks and the stage proceeds to reviewer with a warn-level log. The Go port must preserve this — failing the build gate is NOT a stage-fail, it's a "best effort done, move on" signal. M31's `internal/gates` provides the build-gate Go API; M35.2 calls it.
- **`SECURITY_NOTES_FILE` may be unset.** Bash line 224: `local notes_file="${SECURITY_NOTES_FILE:-}"`. When empty, the bash heredoc still runs (`> ""` errors), but the wrap is in a `{ ... } > "$notes_file"` block that bash silently degrades on. The Go port should explicitly guard: if `notesFile == ""`, skip the write — same operator-visible effect, no panic from `os.Create("")`.

## Seeds Forward

- **M35.1 — Security helpers port:** Lands the Go-native severity classifier + finding parser + escalation writer. Defines the `Finding`, `Severity`, and `Escalator` types every later child consumes. Ships unit tests at ≥80% coverage and golden-file parity against 6 synthetic SECURITY_REPORT.md fixtures. The bash shim that lands here is the bridge that lets M35.1 dogfood independently.
- **M35.2 — Security stage port:** Wraps the M35.1 helpers in a `RunStage(ctx, req)` per the M34 pattern. Wires into `DefaultStageDefs.GoImpl`. Deletes `stages/security.sh`, deletes the `lib/security_helpers.sh` shim, retains `cmd/tekhton/security.go` as an operator-facing debugging CLI surface.
- **M35.3 — Integration cleanup:** Closes the arc. Wedge-audit forbids re-introduction of either bash file. Parity gate (`tests/test_security_parity.sh`) wires into `make dogfood`. CHANGELOG entry. `VERSION` bump. `docs/v4-phase5-stub.md` per-stage matrix updated.
- **M36 — Architect + Intake stage port (next stage in pipeline order):** Follows the same decimal pattern (helpers first, then stage, then cleanup). The Go drift package (`internal/drift.HumanAction.Append`) becomes the universal escalation surface that M36's architect-drift writes also route through — no duplicated escalation logic across stages.
- **Phase 5 stage matrix completion:** With intake (M34) + security (M35) ported, the canonical stage chain has its first two stages in Go. M36 (architect/intake), M37+ (coder), M38+ (review), etc. continue the chain. The M34/M35 pattern (helpers package + stage package + decimal split) is the template — by Phase 5 close every `stages/*.sh` deletes.
- **Universal escalation surface:** `drift.HumanAction` becomes the single Go writer for `HUMAN_ACTION_REQUIRED.md`. Every stage's "we found something a human needs to look at" path routes through it. Per-stage `source` discriminators (`security`, `architect`, `intake`) let operators filter by stage in tooling without losing the unified file format.
