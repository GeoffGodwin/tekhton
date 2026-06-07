<!-- milestone-meta
id: "46"
status: "todo"
-->

# m46 — Replan Detector Body-Grep + Auto-Advance Commit-Skip Cascade

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Two causally chained bugs that bit the user's 2026-06-06 auto-advance run of m37.2 → m38.1 → m38.2 → m38.3. **First bug:** the m37.2 reviewer pass emitted `APPROVED_WITH_NOTES` (correctly extracted by m37.1's parser) but the legacy bash detector `lib/replan_midrun.sh::detect_replan_required` did a body-grep for the literal string "REPLAN_REQUIRED", hit the reviewer's own non-blocking notes that mentioned it (talking about `replanRunner` behavior), and triggered a false-positive operator dialog. **Second bug:** the operator's `[c] Continue` override past the false-positive dialog left a stale sentinel in `.tekhton/.final_check_result` set to 1, which `lib/finalize_commit.sh::_hook_commit` reads on every subsequent iteration and silently skips the commit. Result: m37.2, m38.1, m38.2, m38.3 all finished successfully (causal log confirms `pipeline_end exit_code=0` for each), but ZERO commits fired across ~10 hours of work — 9,139 lines of new Go landed uncommitted in the working tree until the operator manually squashed it into a single "Auto Advance of M37.2, M38.1, M38.2 and M38.3" commit with no per-milestone narrative. |
| **Gap** | (1) `lib/replan_midrun.sh:22` runs `grep -qi "REPLAN_REQUIRED" "$report_file" 2>/dev/null` against the full reviewer report body. The check is case-insensitive AND substring-only — it cannot distinguish the verdict declaration `## Verdict\nREPLAN_REQUIRED` from incidental occurrences in non-blocking notes, drift observations, or coverage gaps. With m37.1's `internal/review/` parser landed, the Go side has typed verdict extraction (`Report.Verdict == VerdictReplanRequired`); the bash detector has no excuse to keep doing string-matching against unparsed body text. (2) `lib/finalize_commit.sh::_hook_commit` (lines 167-200 area) reads `${FINAL_CHECK_RESULT:-0}` AND the persisted sentinel via `_final_check_result_read`. If either is non-zero, `_write_commit_decision "skipped"` fires and `_hook_commit` returns 0 with NO warning to stderr and NO indication in `RUN_SUMMARY.json` that a commit was suppressed. The `[c] Continue` operator path in the bash replan dialog (`lib/replan_midrun.sh::handle_replan_choice` or equivalent) doesn't clear the sentinel — the operator's intent ("ignore the verdict, proceed") was about the verdict, but the side effect (a poisoned sentinel) silently corrupts every downstream iteration in the auto-advance chain. |
| **m46 fills** | Two narrow fixes that together restore auto-advance commit cadence: (1) replace the bash body-grep in `detect_replan_required` with a typed verdict consultation — either exec `tekhton review parse --json $report_file` and read `.Verdict == "REPLAN_REQUIRED"`, OR tighten the grep to scan only the `## Verdict` section anchored by the same heading-and-next-line idiom the m37.1 parser uses; (2) make the bash `[c] Continue` (and `[r]`, `[s]`, `[a]`) override paths in the replan dialog clear `.tekhton/.final_check_result` and `.tekhton/.commit_decision` sentinels before returning, AND emit a stderr warning when `_hook_commit` skips due to a non-zero sentinel so the next failure mode of this shape gets caught at the source. Adds a shim-boundary test driving the false-positive scenario. |
| **Depends on** | m37.1 (uses `internal/review/` parser), m45 (completion gate grace + retry — does NOT cure this bug, but is the most recent reliability-fix touching `_hook_commit`'s adjacent code path) |
| **Files changed** | `lib/replan_midrun.sh`, `lib/finalize_commit.sh`, `internal/stages/review/replan.go` (maybe — if the override path is also wired there), `cmd/tekhton/review.go` (potentially — adds `tekhton review parse --json` subcommand if we go the typed-parser route), `tests/test_replan_detector_verdict_only.sh` (new), `tests/test_autoadvance_commit_after_override.sh` (new) |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m41 | Finalize: stop false-blocking the commit when the milestone block can't be populated |
| m42 | Preflight: guard against no-op TEST_CMD="true" default |
| m43 | Version-bump completeness |
| m44 | Commit subject regression: stop falling back to `.claude/project_version.cfg` |
| m45 | Completion gate: stop false-halting on transient TEST_CMD failure |
| **m46** | **Replan detector false-positive (body-grep) + auto-advance commit-skip cascade (FINAL_CHECK_RESULT sentinel not cleared on operator override)** |

---

## Design

### Sequencing note

m46 is independent of the m38 stage-port arc. Land it whenever convenient.
The risk of NOT landing it is that every auto-advance run with a multi-cycle
reviewer pass (m38.5, m38.6, m39.x — all coming up) is exposed to the same
silent-commit-skip cascade. The 2026-06-06 run lost the per-milestone commit
narrative for 4 milestones and forced a manual squash; future runs hit the
same fate until the sentinel-clear path is fixed.

### Goal 1 — Fix `detect_replan_required` to consult the parsed verdict

**File:** `lib/replan_midrun.sh:22`

Current code:

```bash
# detect_replan_required — Returns 0 if REPLAN_REQUIRED found, 1 otherwise.
detect_replan_required() {
    local report_file="$1"
    [[ -f "$report_file" ]] || return 1
    if grep -qi "REPLAN_REQUIRED" "$report_file" 2>/dev/null; then
        return 0
    fi
    return 1
}
```

The grep is case-insensitive AND scans the full body. Any reviewer report
that *mentions* REPLAN_REQUIRED — in a non-blocking note describing the
replan handler, in a drift observation about the replan subsystem, in a
coverage gap referencing the replan dialog — false-triggers the operator
dialog. The 2026-06-06 m37.2 run's REVIEWER_REPORT.md had three such
incidental mentions, all in `## Non-Blocking Notes`.

Two acceptable fixes. Preference order:

**Option A — Heading-anchored grep (smaller change):**

```bash
detect_replan_required() {
    local report_file="$1"
    [[ -f "$report_file" ]] || return 1
    # Extract the value following the `## Verdict` heading using the same
    # idiom the m37.1 parser uses: heading line + next non-blank line,
    # trimmed. Match only on exact verdict tokens.
    local verdict
    verdict=$(awk '
        /^## Verdict[[:space:]]*$/ {found=1; next}
        found && /^##/ {exit}
        found && NF {print; exit}
    ' "$report_file" 2>/dev/null | tr -d '[:space:]')
    [[ "$verdict" == "REPLAN_REQUIRED" ]]
}
```

This restricts the match to the verdict section only — incidental mentions
elsewhere in the body cannot trigger it.

**Option B — Delegate to the Go parser (cleaner, slightly more invasive):**

Add a `tekhton review parse --json <report>` subcommand in
`cmd/tekhton/review.go` that loads `internal/review.ParseReviewerReport`
and emits the typed `Report` as JSON. The bash detector becomes:

```bash
detect_replan_required() {
    local report_file="$1"
    [[ -f "$report_file" ]] || return 1
    local verdict
    verdict=$(tekhton review parse --json "$report_file" 2>/dev/null \
        | jq -r '.verdict // ""')
    [[ "$verdict" == "REPLAN_REQUIRED" ]]
}
```

Trade-offs: Option B is more idiomatic V4 (no duplicate parser in bash) but
requires the Go subcommand to land first. Option A is a 6-line awk swap.
Land **Option A first**, file Option B as a future cleanup milestone.

### Goal 2 — Clear the commit-skip sentinel on operator override paths

**Files:** `lib/replan_midrun.sh` (the override dispatcher), `lib/finalize_commit.sh` (the sentinel reader).

The `[c] Continue` (and `[r]`, `[s]`, `[a]`) override paths in the bash
replan dialog do not clear `.tekhton/.final_check_result` before returning.
That sentinel is set to 1 by the upstream check that thought the verdict
was REPLAN_REQUIRED — the operator's choice to override the verdict implies
the sentinel value is also invalid, but no code path acts on that implication.

Two pieces:

**Piece A — Clear the sentinel in the override paths.** Find the dispatcher
in `lib/replan_midrun.sh` (around `handle_replan_choice` or equivalent —
audit on entry) and clear the relevant sentinels on EVERY non-replan
choice:

```bash
_clear_commit_skip_sentinels() {
    local tekhton_dir="${TEKHTON_DIR:-.tekhton}"
    rm -f "${tekhton_dir}/.final_check_result" \
          "${tekhton_dir}/.final_check_reason" \
          "${tekhton_dir}/.commit_decision" 2>/dev/null || true
}

handle_replan_choice() {
    local choice="$1"
    case "$choice" in
        c|C)
            _clear_commit_skip_sentinels
            log_info "[replan] Operator chose Continue — clearing commit-skip sentinels and proceeding."
            return 0
            ;;
        # ... other branches
    esac
}
```

**Piece B — Make `_hook_commit` warn-loudly when it skips.** Current
behavior at `lib/finalize_commit.sh:167-200`:

```bash
_hook_commit() {
    local exit_code="$1"
    if [[ "$exit_code" -ne 0 ]]; then
        _write_commit_decision "skipped"
        return 0
    fi
    # ... FINAL_CHECK_RESULT check that also silently writes "skipped" ...
}
```

Add a stderr warning at both skip sites so the next failure mode of this
shape doesn't take 10 hours to notice:

```bash
if [[ "$exit_code" -ne 0 ]]; then
    warn "[_hook_commit] skipped — finalize received exit_code=${exit_code} (pipeline disposition was non-success)"
    _write_commit_decision "skipped"
    return 0
fi
# ... (similar warn at the FINAL_CHECK_RESULT branch — already partially
# present per m41, audit for completeness)
```

The warn goes to the pipeline stderr stream so it surfaces in
`.claude/logs/` AND in the operator-visible terminal output. Today's
silent-skip behavior is what made the 9,139-line uncommitted pile
invisible until end-of-day.

### Goal 3 — Shim-boundary integration tests

**File:** `tests/test_replan_detector_verdict_only.sh` (new, ~80 lines).

Three scenarios:

1. **Heading-anchored REPLAN_REQUIRED → detector returns 0** —
   plant a report with `## Verdict\nREPLAN_REQUIRED` and assert
   `detect_replan_required` returns 0 (true).
2. **APPROVED_WITH_NOTES with REPLAN_REQUIRED in body → detector
   returns 1** — plant a report with `## Verdict\nAPPROVED_WITH_NOTES`
   and a non-blocking note that mentions `REPLAN_REQUIRED`. Assert
   `detect_replan_required` returns 1 (false). This is the regression
   guard for today's m37.2 false-positive.
3. **Missing `## Verdict` heading, inline body fallback → detector
   returns 1** — plant a report with no `## Verdict` heading and
   `REPLAN_REQUIRED` only in the body. The detector should NOT trigger;
   the m37.1 parser's inline-fallback path is for unparsed reports, not
   for the override-dialog detector. Distinct concerns.

**File:** `tests/test_autoadvance_commit_after_override.sh` (new, ~100 lines).

Drives the override-then-next-iteration scenario:

1. Plant a `.tekhton/.final_check_result` sentinel containing "1".
2. Plant a `REVIEWER_REPORT.md` with verdict APPROVED.
3. Source the replan-dispatcher and invoke `handle_replan_choice c`.
4. Assert the sentinel files no longer exist.
5. Drive a no-op `_hook_commit` call with exit_code=0 and confirm it does
   NOT skip due to a leftover sentinel.

Both tests self-skip cleanly when the Go binary isn't built — same
pattern as `tests/test_state_writer_resume_fields.sh`.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `lib/replan_midrun.sh` | Modify | Replace `detect_replan_required`'s body-grep with the heading-anchored awk (Option A); add `_clear_commit_skip_sentinels` helper; call it from the `[c]/[r]/[s]/[a]` dispatch branches. |
| `lib/finalize_commit.sh` | Modify | Add `warn` calls at the two `_hook_commit` skip sites so the silent-skip-cascade is loud the next time it happens. |
| `tests/test_replan_detector_verdict_only.sh` | Create | Three-scenario regression guard for Goal 1. |
| `tests/test_autoadvance_commit_after_override.sh` | Create | Drives the override-then-next-iteration sentinel-clear scenario for Goal 2. |
| `docs/v4-phase5-stub.md` | Modify (optional) | Note the body-grep → typed-parser delegation as a future cleanup; record Option B (`tekhton review parse --json`) as Seeds Forward. |

---

## Acceptance Criteria

- [ ] `lib/replan_midrun.sh::detect_replan_required` no longer contains
      the case-insensitive body-grep `grep -qi "REPLAN_REQUIRED"`.
      Verified by `! grep -nE 'grep .* REPLAN_REQUIRED' lib/replan_midrun.sh`
      returning matches.
- [ ] A reviewer report with `## Verdict\nAPPROVED_WITH_NOTES` followed
      by non-blocking notes that mention `REPLAN_REQUIRED` does NOT
      trigger `detect_replan_required`. Verified by scenario 2 of
      `tests/test_replan_detector_verdict_only.sh`.
- [ ] A reviewer report with `## Verdict\nREPLAN_REQUIRED` DOES trigger
      `detect_replan_required`. Verified by scenario 1.
- [ ] `lib/replan_midrun.sh` contains a `_clear_commit_skip_sentinels`
      function that removes `.tekhton/.final_check_result`,
      `.tekhton/.final_check_reason`, and `.tekhton/.commit_decision`.
      Verified by `grep -nE 'rm -f.*final_check_result' lib/replan_midrun.sh`
      returning at least one match inside the function body.
- [ ] The `[c]/[r]/[s]/[a]` dispatch branches each invoke
      `_clear_commit_skip_sentinels` before returning. Verified by
      `grep -B 5 '_clear_commit_skip_sentinels' lib/replan_midrun.sh`
      showing it called inside each case arm.
- [ ] `lib/finalize_commit.sh::_hook_commit` emits a stderr warning when
      it skips due to non-zero exit_code OR non-zero
      `FINAL_CHECK_RESULT`. Verified by
      `grep -nE 'warn.*_hook_commit.*skip' lib/finalize_commit.sh`
      returning at least two matches.
- [ ] After invoking `handle_replan_choice c` against a pre-planted
      sentinel value of "1", neither `.tekhton/.final_check_result` nor
      `.tekhton/.commit_decision` exists on disk. Verified by scenario
      in `tests/test_autoadvance_commit_after_override.sh`.
- [ ] All new tests pass:
      `bash tests/test_replan_detector_verdict_only.sh` and
      `bash tests/test_autoadvance_commit_after_override.sh`.
- [ ] No regression in existing tests:
      `tests/test_replan_*.sh` (if any),
      `tests/test_finalize_commit_*.sh` (if any),
      `internal/finalize/...` Go tests.
- [ ] `shellcheck lib/replan_midrun.sh lib/finalize_commit.sh
      tests/test_replan_detector_verdict_only.sh
      tests/test_autoadvance_commit_after_override.sh` returns zero
      warnings.
- [ ] Full suite passes: `bash tests/run_tests.sh` + `go test ./...`.

## Watch For

- The awk extraction in Goal 1 Option A must handle BOTH common verdict
  shapes: `## Verdict\nAPPROVED` (heading then value on next line) AND
  `## Verdict APPROVED` (value on same line as heading). The current
  m37.1 parser's `extractVerdictFromAccum` handles both — match its
  behavior so bash and Go agree byte-for-byte on the verdict.
- `_clear_commit_skip_sentinels` must use `2>/dev/null || true` to stay
  silent on the common case where the sentinels don't exist yet. The
  helper should NEVER fail the dispatcher.
- The `warn` calls in `_hook_commit` are intentional surface — operators
  need to SEE that the commit was skipped, not infer it after the fact.
  Don't downgrade to `log_verbose` or stderr-only. Use the same `warn`
  helper the rest of the finalize hooks use so the output lands in the
  pipeline summary.
- The bash dispatch for `[c]/[r]/[s]/[a]` may live in a different file
  than `lib/replan_midrun.sh` — audit on entry. The interactive prompt
  in `internal/stages/review/replan.go` (Go side) has its own dispatcher
  too; if that's what the user hit, the sentinel-clear logic needs to
  live in BOTH places.
- The 2026-06-06 root cause that motivated this milestone (m37.2's
  reviewer report incidentally mentioning REPLAN_REQUIRED three times
  in non-blocking notes) is rare-but-real. The reviewer was working on
  the review stage port itself, so writing about REPLAN_REQUIRED in
  notes was unavoidable. Future stage-port milestones for the replan
  subsystem (m47+ candidates) will hit this same shape — the heading-
  anchored detector is a permanent improvement, not a one-off.
- The completion-gate `m45` grace + retry does NOT cure this bug. The
  FINAL_CHECK_RESULT sentinel is set EARLIER (by the bash replan dialog
  trigger), not by the completion gate's TEST_CMD result. These are
  two distinct sentinel-write sites; m45 fixes one, m46 fixes another.

## Seeds Forward

- **`tekhton review parse --json` subcommand (Option B from Goal 1):**
  add a CLI surface that emits the typed `internal/review.Report` as
  JSON. Bash detectors (and external tooling) consume it instead of
  re-implementing parsing. Tracked as a future cleanup; not scheduled.
- **Sentinel-life-cycle audit (post-m46 candidate):** the `.tekhton/`
  sentinel files (`.final_check_result`, `.final_check_reason`,
  `.commit_decision`, others) are scattered across multiple hooks with
  no central reader/writer. A future arc could consolidate the sentinel
  vocabulary into `internal/finalize/sentinels.go` with typed `Get/Set/
  Clear` helpers and make sentinel-life-cycle bugs harder to introduce.
- **Operator-override telemetry:** every time the operator hits a
  `[c]/[r]/[s]/[a]` dispatch, log a `replan_dialog_override` event to
  the causal log with the verdict-as-detected and the operator's
  choice. Lets future analysis spot whether `[c] Continue` is being
  hit because of real false-positives (this milestone's bug) or
  because operators are routinely overriding legitimate REPLAN
  verdicts (which would signal a different problem).
- **Auto-advance per-milestone commit confirmation:** after each
  auto-advance iteration, surface a one-line summary
  ("✓ m38.1 committed as <hash>" or "⚠ m38.1 finalize skipped commit")
  before the loop moves on. Makes the silent-skip cascade impossible to
  miss the next time the underlying mechanism breaks.
