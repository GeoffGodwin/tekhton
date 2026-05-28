<!-- milestone-meta
id: "32"
status: "split"
-->

# m32 — Diagnose Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — sixth Ship-of-Theseus bash subsystem to port. The diagnose engine is the user-facing failure-explanation surface: `tekhton --diagnose`, the post-crash first-aid printer, the `_dashboard_diagnosis` JSON writer, and the inline classifier the stage-failure path calls from `coder_buildfix.sh`, `hooks_final_checks.sh`, and `finalize_commit.sh`. M17 already ported the error classifier (`internal/errors/`) and shipped the `tekhton diagnose classify / classify-agent / recovery / redact / is-transient` CLI surface. What remains in bash is the *engine* — the orchestrator that aggregates causal-log / RUN_SUMMARY / LAST_FAILURE_CONTEXT into a diagnosis, the rule registry that classifies the aggregated picture into a recovery suggestion, the report writer that prints the operator-facing diagnosis, and the remediation helper that turns a classification into an executable safe-list suggestion. 10 bash files, ~1,846 LOC (out of the 2,129 total under `lib/diagnose*.sh` + `lib/remediation.sh` — the registry file `diagnose_rules_registry.sh` ports as data inside the rules sub-package). Without this port, every stage failure still hands control back to bash to render its explanation. |
| **Gap** | `lib/diagnose.sh` (270L) + `lib/diagnose_helpers.sh` (182L) + the five rule files (`diagnose_rules.sh` 277L, `diagnose_rules_extra.sh` 271L, `diagnose_rules_migration.sh` 93L, `diagnose_rules_resilience.sh` 257L, `diagnose_rules_resilience_preflight.sh` 79L) + the registry (`diagnose_rules_registry.sh` 38L) + the output pair (`diagnose_output.sh` 281L, `diagnose_output_extra.sh` 98L) + `lib/remediation.sh` (283L) total 2,129 LOC of bash that run on every failed pipeline. M17 made the *classifier* Go-native but kept the engine that *uses* the classifier in bash — `_read_diagnostic_context` aggregates the inputs in bash, `classify_failure_diag` applies the bash rule registry, `generate_diagnosis_report` writes the report in bash, and `emit_dashboard_diagnosis` writes the Watchtower JSON in bash. The Go `tekhton diagnose classify` subcommand is islanded: it takes a log file, returns a category — but the engine that decides *what to do with that category* (recovery suggestions, cause-chain rendering, dashboard payload, remediation execution) is still bash. |
| **m32 fills** | The full diagnose engine ports to `internal/diagnose/` across three sequenced child milestones, each independently dogfood-able and shipping a parity gate against a frozen v3 bash baseline. **M32.1 — Engine + helpers:** `internal/diagnose/{engine.go, helpers.go}`, the orchestrator + context reader + cause-chain collapser + recurring-failure detector. Defines the `Rule` and `Diagnosis` interfaces every later child plugs into, and creates the `internal/proto/diagnosis_v1.go` envelope that the dashboard contract rides on. **M32.2 — Rule registry + 18 rules:** `internal/diagnose/rules/` sub-package, one Go file per source bash file, with priority-ordered `Register()` calls into the M32.1 engine. **M32.3 — Output + remediation:** `internal/diagnose/{output.go, remediation.go}`, the report writer, crash first-aid printer, dashboard JSON emitter, and the safe-list remediation runner; this is where the LOC delete + `VERSION` bump lands. All three preserve the bash semantics of the m17-shipped CLI surface (no behavior change to `tekhton diagnose classify` / `classify-agent` / `recovery` / `redact` / `is-transient`); m32 adds `tekhton diagnose run` (the engine) and `tekhton diagnose crash <type>` (the standalone first-aid lever). |
| **Depends on** | m27 |
| **Files changed** | `internal/diagnose/` (new package, ~1,300 Go LOC across engine + helpers + output + remediation), `internal/diagnose/rules/` (new sub-package, ~900 Go LOC across 18 rule files + registry), `internal/proto/diagnosis_v1.go` (new — dashboard contract), `cmd/tekhton/diagnose.go` (modify — add `run` + `crash` subcommands; existing m17 subcommands untouched), the 10 `lib/diagnose*.sh` + `lib/remediation.sh` files (delete in m32.3), `tekhton-legacy.sh` (modify — replace the `--diagnose` early-check at line 657-659 with an exec into `tekhton diagnose run`; replace the inline-classifier call sites in `stages/coder_buildfix.sh`, `hooks_final_checks.sh`, `lib/finalize_commit.sh` with an exec into `tekhton diagnose classify` from the already-ported m17 surface), parity test `tests/test_diagnose_parity.sh` (new in m32.3). |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m17 | Error taxonomy wedge — classifier + pattern registry + `tekhton diagnose classify/redact/recovery` ported to Go; engine stayed bash. |
| m25 | Drift/clarify port — `failure_context.sh` ported to `internal/failure_context/`; the diagnose engine consumes its slot helpers via the m17-shipped recovery CLI. |
| m27 | Bash env hardening + audit gates — the diagnose engine reads `${PROJECT_DIR}`, `${TEKHTON_HOME}`, `${BUILD_ERRORS_FILE}`, `${MIGRATION_BACKUP_DIR}`, `${DASHBOARD_DIR}`; m27's audit caught one unguarded read in `diagnose_output_extra.sh`. m32 inherits a clean baseline. |
| **m32** | **Diagnose engine + rules + output + remediation ported to Go; bash diagnose subsystem deletes; M131/M133 resilience-arc rules preserved byte-for-byte against a frozen v3 baseline.** |

---

## Design

### Sequencing note

m32 is the largest subsystem in the Phase 5 batch (1,846 LOC of in-scope bash). A three-child split is mandatory: M32.1 lands the engine framework with zero rule changes (the bash rule registry continues to drive classification via a `BashRuleAdapter` shim during the transition); M32.2 fills the registry with Go-native rules one-per-file behind a registry pattern; M32.3 takes ownership of output + remediation and is where the bash file deletes + `VERSION` bump land. Each child runs its own dogfooded `tekhton run --milestone m32.X --complete` cycle. Premature collapse into one milestone has been tried in the m21/m22 retros (17 + 9 patch-bumps respectively) and a 1,846-LOC port would likely produce >25 patch-bumps in a single arc — not survivable.

### Goal 1 — `internal/diagnose/` package shape

The Go-side package layout mirrors the bash partition exactly so a reader who knows the bash can navigate the Go:

```
internal/diagnose/
├── engine.go              # M32.1 — orchestrator + Diagnosis aggregate type
├── engine_test.go         # M32.1
├── helpers.go             # M32.1 — _collapse_cause_chain, _detect_recurring_failures, _collect_agent_log_tails
├── helpers_test.go        # M32.1
├── output.go              # M32.3 — generate_diagnosis_report, print_diagnosis_summary, write_last_failure_context
├── output_test.go         # M32.3
├── remediation.go         # M32.3 — attempt_remediation + blocklist + 2-attempt cap + JSONL log
├── remediation_test.go    # M32.3
├── crash.go               # M32.3 — print_crash_first_aid (standalone, no engine needed)
├── crash_test.go          # M32.3
├── dashboard.go           # M32.3 — emit_dashboard_diagnosis (writes internal/proto/diagnosis_v1 envelope)
├── dashboard_test.go      # M32.3
├── rules/
│   ├── registry.go        # M32.2 — priority-ordered slice from diagnose_rules_registry.sh
│   ├── registry_test.go   # M32.2 — order-mismatch test
│   ├── core.go            # M32.2 — diagnose_rules.sh body (8 rules)
│   ├── extra.go           # M32.2 — diagnose_rules_extra.sh body (6 rules)
│   ├── migration.go       # M32.2 — diagnose_rules_migration.sh body (2 rules)
│   ├── resilience.go      # M32.2 — diagnose_rules_resilience.sh body (3 rules)
│   ├── resilience_preflight.go  # M32.2 — diagnose_rules_resilience_preflight.sh body (1 rule)
│   └── rules_test.go      # M32.2 — table-driven per-rule + cross-rule priority test
└── testdata/
    ├── fixtures_v3/       # Frozen pre-m32 baselines (15 scenarios)
    └── synthetic/         # Per-rule synthetic context fixtures
```

### Goal 2 — `tekhton diagnose run` and `tekhton diagnose crash` CLI surface

Existing m17 `tekhton diagnose` subcommands (`classify`, `classify-agent`, `recovery`, `redact`, `is-transient`) stay unchanged — they are the operator-facing primitives downstream tooling already consumes. M32 adds:

```
tekhton diagnose run                         # Replaces lib/diagnose.sh::run_diagnose
                                              #   Reads PIPELINE_STATE / RUN_SUMMARY / LAST_FAILURE_CONTEXT / CAUSAL_LOG
                                              #   Applies rule registry, prints report, exits with diagnosis confidence
tekhton diagnose crash <stage>               # Standalone — print_crash_first_aid only
                                              #   <stage> = intake | coder | reviewer | tester | finalize | unknown
```

`tekhton diagnose run` is what the `tekhton-legacy.sh:657-659` early-check block becomes after M32.3: a one-line exec into the Go binary. `tekhton diagnose crash` is what the stage-failure hook calls when a stage exits non-zero before the engine has artifacts to read (the `_DIAG_PIPELINE_STAGE` slot is empty — the crash printer is the fallback).

### Goal 3 — `internal/errors/` integration (m17 dependency, no duplication)

The diagnose engine **consumes** the m17 classifier; it must not re-implement classification logic. Concretely:

```go
// internal/diagnose/engine.go
package diagnose

import "github.com/tekhton/tekhton/internal/errors"

func (e *Engine) Classify(ctx context.Context, in *Context) Diagnosis {
    // Step 1: short-circuit on success outcome (matches bash classify_failure_diag).
    if in.Outcome == "success" {
        return Diagnosis{Classification: "SUCCESS", Confidence: errors.ConfidenceHigh}
    }

    // Step 2: try the rule registry (M32.2). Each rule is allowed to call
    //         errors.ClassifyAgent / errors.Recovery / errors.Patterns
    //         on the input context but MUST NOT implement its own regex
    //         classifier — that's m17's job.
    for _, rule := range e.rules {
        if d, ok := rule.Match(in); ok {
            d.Recurring = e.helpers.detectRecurring(in)
            return d
        }
    }

    // Step 3: unknown fallback — the registry's last entry (_rule_unknown) always matches.
    return Diagnosis{Classification: "UNKNOWN", Confidence: errors.ConfidenceLow}
}
```

`internal/diagnose/rules/*.go` files call `errors.ClassifyAgent(...)` when they need to consult the m17 pattern registry; they never `import "regexp"` themselves for classification regexes. The lint hook in `scripts/wedge-audit.sh` extends in M32.2 to enforce this: a `regexp` import inside `internal/diagnose/rules/` fails the audit.

### Goal 4 — `internal/proto/diagnosis_v1.go` envelope (the Watchtower contract)

`emit_dashboard_diagnosis` writes a small JSON object to `${DASHBOARD_DIR}/data/diagnosis.js` that the Watchtower TUI dashboard reads. The current bash version hand-rolls the JSON with `printf` and `sed`-based escaping; M32.1 introduces a typed envelope all three children share:

```go
// internal/proto/diagnosis_v1.go
package proto

type DiagnosisV1 struct {
    Available       bool     `json:"available"`
    Classification  string   `json:"classification,omitempty"`
    Confidence      string   `json:"confidence,omitempty"`
    Stage           string   `json:"stage,omitempty"`
    CauseChain      string   `json:"cause_chain,omitempty"`
    Suggestions     []string `json:"suggestions,omitempty"`
    RecurringCount  int      `json:"recurring_count"`
    SchemaVersion   int      `json:"schema_version"`     // = 1 in M32
}
```

The byte-on-disk format must continue to be `TK_DIAGNOSIS = <json>;` — `_write_js_file` semantics — so the existing TUI parser keeps working. M32.1 ships the envelope; M32.3 wires it into `dashboard.go`.

### Goal 5 — Parity-gate strategy (frozen v3 baselines)

The Resilience Arc rules (m126-m138 in V3 history) were a major design effort. Every rule's match pattern and recovery-suggestion text is operator-visible vocabulary. M32.3 ships a parity gate (`tests/test_diagnose_parity.sh`) that runs 15 frozen scenarios captured at `v4.27.0-dogfood` against the Go engine and asserts byte-identical output after timestamp / PID / path normalization:

| Scenario | Source | What it exercises |
|----------|--------|-------------------|
| crash-no-state | Run with no pipeline ever started | `print_crash_first_aid` only |
| crash-quota | `QUOTA_PAUSED` file present | First-aid quota branch |
| crash-build-errors | `BUILD_ERRORS.md` non-empty | First-aid build branch |
| crash-resumable | `PIPELINE_STATE.md` with exit_stage | First-aid resume branch |
| crash-transient | Recent log with rate-limit pattern | First-aid transient branch |
| ui-gate-interactive-reporter | M133 Playwright html-reporter timeout | Resilience rule #1 |
| build-fix-exhausted | M128 build-fix loop give-up | Resilience rule #2 |
| preflight-interactive-config | M131 preflight detected interactive cfg | Resilience preflight rule |
| max-turns-coder | Coder hit MAX_TURNS | Core rule `_rule_max_turns` |
| review-loop | 3+ reviewer cycles | Core rule `_rule_review_loop` |
| security-halt | Reviewer flagged secret leak | Core rule `_rule_security_halt` |
| intake-clarity | Intake exited with clarity-needed | Core rule `_rule_intake_clarity` |
| migration-crash | Migration backup dirs present, no state | Migration rule |
| version-mismatch | VERSION drift detected | Migration rule |
| mixed-classification | M127 code+noncode log mix | Extra rule `_rule_mixed_classification` |

Each scenario lives under `internal/diagnose/testdata/fixtures_v3/<scenario>/` with the v3-captured `DIAGNOSIS.md`, `LAST_FAILURE_CONTEXT.json`, and `data/diagnosis.js` baselines. The gate runs `tekhton diagnose run --project-dir <fixture>` and diffs each output. M32.1 captures the baselines (under tag `v4.31.99-diagnose-baseline`, committed before any Go work starts on M32.2). M32.2 verifies rules against the captured baselines incrementally. M32.3 wires the gate into `make dogfood`.

### Goal 6 — Bash caller migration (two call paths preserved)

The diagnose engine is invoked from two contexts; **both must keep working** through every milestone in the arc:

1. **Inline (stage-failure path).** `stages/coder_buildfix.sh`, `hooks_final_checks.sh`, `lib/finalize_commit.sh` source `lib/diagnose.sh` and call `classify_failure_diag` directly to decide whether to retry or fail-fast. After M32.3, these callers exec `tekhton diagnose classify` (m17-shipped) and parse the routing token — no diagnose-engine state shared in-process.
2. **Standalone (operator-facing).** `tekhton --diagnose` (early-check at `tekhton-legacy.sh:657-659`) ran the full engine and printed the report. After M32.3, the early-check becomes `exec "$TEKHTON_BIN" diagnose run "$@"`.

The `tekhton diagnose classify` / `classify-agent` / `recovery` / `redact` / `is-transient` subcommands shipped in m17 are operator-facing primitives consumed by downstream tooling; **they must not break**. M32.2 and M32.3 add new subcommands (`run`, `crash`); they do not modify the m17-shipped ones.

### Goal 7 — `_diag_emit_rule` one-liner preservation

Operators have built grep-pipelines around the rule-emit one-liner format the bash engine writes to stderr when a rule matches:

```
[diag] rule=_rule_ui_gate_interactive_reporter confidence=high classification=UI_GATE_INTERACTIVE_REPORTER stage=tester
```

The Go port preserves this format byte-for-byte. `internal/diagnose/engine.go` emits the line via a small helper:

```go
func (e *Engine) emitRuleMatch(r Rule, d Diagnosis) {
    fmt.Fprintf(e.logger, "[diag] rule=%s confidence=%s classification=%s stage=%s\n",
        r.Name(), d.Confidence, d.Classification, d.Stage)
}
```

Parity gate scenario `rule-emit-format` (added in M32.2) asserts byte-identical stderr line for every rule against the v3 baseline.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `.claude/milestones/m32.1-diagnose-engine.md` | Create | Child milestone — engine + helpers port. |
| `.claude/milestones/m32.2-diagnose-rules.md` | Create | Child milestone — rule registry + 18 rules port. |
| `.claude/milestones/m32.3-diagnose-output-and-remediation.md` | Create | Child milestone — output + remediation + crash + dashboard port; bash file deletes; VERSION bump. |
| `.claude/milestones/MANIFEST.cfg` | Modify (by human at review pass) | Add four rows for m32 / m32.1 / m32.2 / m32.3. Not authored by this milestone — the human owns it. |

---

## Acceptance Criteria

- [ ] All three child milestone files (`m32.1-diagnose-engine.md`, `m32.2-diagnose-rules.md`, `m32.3-diagnose-output-and-remediation.md`) exist under `.claude/milestones/` and pass the m85 acceptance-criteria linter.
- [ ] Each child's `Depends on` row in `## Overview` matches the corresponding `depends_on` column in `MANIFEST.cfg` (m32.1 depends on m27; m32.2 depends on m32.1; m32.3 depends on m32.2).
- [ ] No bash files under `lib/diagnose*.sh` or `lib/remediation.sh` are deleted by this parent milestone — deletions live in M32.3.
- [ ] No `VERSION` bump happens at the parent level — the bump lives in M32.3 on close (`4.32.0`).
- [ ] `internal/diagnose/` does not yet exist on disk when this parent is filed (the children create it); the parent only authors the design.
- [ ] The parent's status in `MANIFEST.cfg` is `split` (not `todo` / `in_progress` / `done`); the runtime treats split-status parents as descriptive-only and does not schedule them for execution.

## Watch For

- **Diagnose runs in TWO contexts.** The inline (stage-failure) path and the standalone (`tekhton --diagnose`) path must keep working through every milestone in the arc. Premature deletion of `lib/diagnose.sh` before M32.3 breaks the inline path. Each child's wedge pattern (engine seam without removing bash callers) is what protects this — do not collapse two children into one.
- **The m17-shipped `tekhton diagnose classify / classify-agent / recovery / redact / is-transient` subcommands MUST NOT be modified or broken.** They are operator-facing primitives consumed by downstream tooling (CI gates, build-fix scripts, the m25 drift router). M32 adds two new subcommands (`run`, `crash`); it does not touch the m17 ones.
- **The `_diag_emit_rule` one-liner format is operator vocabulary.** `[diag] rule=NAME confidence=LEVEL classification=CLASS stage=STAGE` is grep-piped in operator dashboards. Byte-for-byte parity required. The parity gate enforces this.
- **The `_dashboard_diagnosis` JSON is contract-typed in M32.1.** `internal/proto/diagnosis_v1.go` is created in M32.1 (not M32.3) because both the rules sub-package (M32.2) and the dashboard emitter (M32.3) depend on it. Defining the envelope upfront avoids a churn diff in M32.3.
- **The Resilience Arc rules (M133 series) are the highest-value parity surface.** Three resilience rules (`ui_gate_interactive_reporter`, `build_fix_exhausted`, `preflight_interactive_config`) plus the m131 preflight rule were the V3 design's marquee output. Every match pattern, every confidence threshold, every suggestion-text wording must be preserved byte-for-byte. Capture v3 baselines BEFORE any Go work starts in M32.2 — once the bash files delete in M32.3, the baselines are the only artifact.
- **`lib/remediation.sh` was renamed from `lib/error_patterns_remediation.sh` in m17.** The Go port lands at `internal/diagnose/remediation.go` (kept inside the diagnose package because operators experience the safe-list runner as part of the diagnosis report — they're one workflow). Do NOT move it to `internal/errors/remediation.go` even though the file name suggests "errors" lineage; the m17 rename was a renaming-only refactor, not a relayering signal.
- **The `diagnose_rules_registry.sh` file (38 LOC) is data, not logic.** It ports as a single Go slice in `internal/diagnose/rules/registry.go`. The order matters (priority-ordered, top-down match) — an order-mismatch test (mirroring m21's `TestHookOrder_MatchesBashRegistration`) lives in `registry_test.go`.

## Seeds Forward

- **M32.1 — Engine + helpers:** Lands the framework. Defines the `Rule` and `Diagnosis` types every later child plugs into. Creates `internal/proto/diagnosis_v1.go`. Ships a `BashRuleAdapter` shim that lets the M32.1 engine call the still-bash rule registry — so M32.1 is independently dogfood-able without M32.2's Go rules being ready yet.
- **M32.2 — Rule registry + 18 rules:** Replaces the `BashRuleAdapter` with a Go-native registry. Each rule file (`core.go`, `extra.go`, `migration.go`, `resilience.go`, `resilience_preflight.go`) registers via a `Register()` call. Parity gate scenarios for all 18 rules + the cross-rule priority test land here.
- **M32.3 — Output + remediation + crash + dashboard:** Closes the arc. Port `output.go` + `crash.go` + `dashboard.go` + `remediation.go`. Delete all 10 bash files (`lib/diagnose*.sh` + `lib/remediation.sh`). Rewire `tekhton-legacy.sh:657-659`. Bump `VERSION` to `4.32.0`. Parity gate `tests/test_diagnose_parity.sh` wired into `make dogfood`.
- **M33 — Migrate command port (next arc):** With diagnose done, the migrate/health/init subsystem becomes the next portable target. Diagnose-emitted `MIGRATION_BACKUP_DIR` detection in `_rule_migration_crash` foreshadows the M33 migrate-port's responsibility for managing those backup dirs Go-natively.
- **V5 multi-provider error mapping:** Provider-specific errors will surface via m17 sentinels (`ErrTransient`, `ErrUpstreamLimit`); diagnose rules learn to consume them as a *signal source* (next to existing causal-log / LAST_FAILURE_CONTEXT sources). The clean engine→rule→errors layering m32 establishes is what makes that V5 extension a one-rule-add operation rather than an engine rewrite.
- **Diagnose-driven auto-remediation expansion:** `lib/remediation.sh` today caps at 2 attempts per gate invocation with a hardcoded blocklist. The Go port (`internal/diagnose/remediation.go`) opens the door to a typed `RemediationPolicy` (configurable per-project blocklist + per-classification max-attempts) — a future arc, not m32 scope.
