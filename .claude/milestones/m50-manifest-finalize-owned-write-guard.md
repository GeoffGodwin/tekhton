<!-- milestone-meta
id: "50"
status: "todo"
-->

# m50 — MANIFEST.cfg is Finalize-Owned: Block Coder/Stage Writes via a Pre-Commit Guard

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | The m48 coder agent's run at `51aff09` (2026-06-07 23:32) appended 69 spurious m01.x lines to `MANIFEST.cfg` and flipped m01 from `done` to `split`. The coder almost certainly invoked the milestone-split subroutine against m01 as a test fixture while implementing `clearAutoAdvanceIterationState`, and each invocation appended new children without cleanup. The corruption survived into the commit, and the next morning the auto-advance loop did exactly what it was designed to do: it saw `m01|split` with 38 pending `m01.1` children, picked the lexicographically smallest frontier id (m01.1 < m49 byte-wise), and ran two ceremonial no-op milestones (`66a2455`, `4c57231`) overnight whose bodies explicitly say *"no code changes were required; the work shipped previously."* Lost ~3 hours of operator attention to diagnosis and recovery. The bug class is real and will recur — any future coder agent that needs to invoke split logic, or even mistakenly edits MANIFEST.cfg while exploring the codebase, can trigger the same cascade. |
| **Gap** | `MANIFEST.cfg` is the source of truth for milestone state. By design, it should ONLY be mutated by the finalize chain (`_hook_mark_done`, the bash side of milestone advancement, and the Go-side manifest CLI). No coder, reviewer, tester, or any stage agent has a legitimate reason to write to it during normal pipeline operation. But today nothing enforces this. The bash `lib/finalize_commit_staging.sh` builds the commit-staging allowlist by including CODER_SUMMARY's `## Files Modified` section, the bookkeeping prefixes (`.tekhton/`, `.claude/`, `VERSION`, etc.), and any other coder-asserted file paths. If the coder writes to MANIFEST.cfg, that write gets staged, gets committed, and gets pushed — silently. No commit hook intercepts it. No validation catches it. The Go side has the same gap: `internal/finalize/` writes to MANIFEST.cfg via the manifest package, but there's no guard preventing other code paths from doing the same. The m48 incident was the first observed manifestation of this; the next one is a matter of when, not if. |
| **m50 fills** | A pre-commit guard implemented in the Go finalize-commit path (and a defense-in-depth bash check in `lib/finalize_commit.sh`). The guard runs IMMEDIATELY before `git commit` and inspects the staged file list. If `.claude/milestones/MANIFEST.cfg` is staged AND the current commit is NOT a finalize-hook-initiated commit (detected via a Go-managed sentinel `.tekhton/.finalize_active`), the guard aborts the commit with a clear error message: `"refusing to commit MANIFEST.cfg from stage <coder|review|tester>: this file is finalize-owned."`. Optional cleanup: `git restore --staged .claude/milestones/MANIFEST.cfg` so the rejected stage can re-attempt without manual cleanup. Adds: (1) the sentinel writer in `internal/finalize/orchestrator.go` (sets `.tekhton/.finalize_active` at finalize start, clears it at finalize end); (2) the staging-guard helper in `lib/finalize_commit.sh` (~25 LOC); (3) a Go-side guard at the `cmd/tekhton/run.go` post-stage commit path; (4) a tightening of the coder prompt in `prompts/coder.prompt.md` instructing the agent not to write MANIFEST.cfg; (5) two regression tests — a Go unit test exercising the staged-file inspection logic and a shim-boundary test that drives a synthetic stage-time commit trying to include MANIFEST.cfg and asserts rejection. |
| **Depends on** | none (purely internal to the commit-staging path) |
| **Files changed** | `lib/finalize_commit.sh`, `internal/finalize/orchestrator.go`, `cmd/tekhton/run.go`, `prompts/coder.prompt.md`, `internal/finalize/orchestrator_test.go`, `tests/test_manifest_write_guard.sh` (new) |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m41 | Finalize: stop false-blocking commit when milestone block can't be populated |
| m42 | Preflight: guard against no-op TEST_CMD |
| m43 | Version-bump completeness |
| m44 | Commit subject regression |
| m45 | Completion gate: stop false-halting on transient TEST_CMD failure |
| m46 | Replan detector body-grep + commit-skip cascade |
| m47 | Stage verdict envelope is source of truth |
| m48 | Auto-advance loop: reset per-iteration state |
| m49 | Security gate skip: H3 recognition + fail-closed |
| **m50** | **MANIFEST.cfg is finalize-owned: block stage-agent writes via a pre-commit guard** |

---

## Design

### Sequencing note

m50 runs after m39.4 in the auto-advance chain. m39.4 is the V4 closer; once
it ships, m50 caps off the reliability-fixes arc with one final guard
against the bug class that wasted 3 hours overnight. The implementation
surface is small and the test path is well-defined; m50 should be one of
the cheapest auto-advance milestones to run.

### Core principle

> `.claude/milestones/MANIFEST.cfg` is owned by the finalize chain.
> Any commit that stages a change to this file MUST be initiated by
> the finalize orchestrator. Coder, reviewer, tester, security, and
> any other stage agent has zero legitimate reason to write to it
> during normal pipeline operation. Attempts to do so are
> intercepted at the pre-commit boundary and rejected with a
> structured error.

### Goal 1 — Finalize-active sentinel

**Files:** `internal/finalize/orchestrator.go`, `cmd/tekhton/run.go`.

Add a sentinel file `.tekhton/.finalize_active` that the finalize
orchestrator writes at the start of its hook chain and removes at the
end. The pre-commit guard (Goal 2) consults this sentinel to
distinguish finalize-initiated commits from stage-initiated commits.

```go
// internal/finalize/orchestrator.go — at the top of Run, just after
// loading config and before invoking the hook chain.
func (o *Orchestrator) Run(ctx context.Context, in *Input) error {
    // m50 — Mark the finalize chain as active. Pre-commit guards (in
    // both bash lib/finalize_commit.sh and Go cmd/tekhton/run.go)
    // consult this sentinel to allow MANIFEST.cfg writes that
    // legitimately come from _hook_mark_done. Cleared in the deferred
    // tail so a panic mid-finalize doesn't poison subsequent runs.
    sentinelPath := filepath.Join(in.ProjectDir, ".tekhton", ".finalize_active")
    if err := os.MkdirAll(filepath.Dir(sentinelPath), 0o755); err == nil {
        if err := os.WriteFile(sentinelPath, []byte(in.Timestamp+"\n"), 0o644); err != nil {
            // Non-fatal — log only.
            fmt.Fprintf(in.Log, "finalize: warning: write %s: %v\n", sentinelPath, err)
        }
    }
    defer func() {
        _ = os.Remove(sentinelPath)
    }()

    // ... existing hook-chain dispatch unchanged
}
```

### Goal 2 — Bash pre-commit guard

**File:** `lib/finalize_commit.sh`.

Add a helper `_check_manifest_write_guard` that runs immediately
before `git commit -m`. The check:

```bash
# m50 — Refuse to commit MANIFEST.cfg from any stage that is not the
# finalize chain. The chain marks itself active by writing the sentinel
# .tekhton/.finalize_active in internal/finalize/orchestrator.go::Run;
# its absence here means a stage agent (coder/reviewer/tester/security/etc.)
# is the one attempting the write — exactly the m48 / 51aff09 scenario.
#
# Behavior: log a warning, unstage MANIFEST.cfg, and continue with the
# rest of the changeset. The intent is "the rest of the changeset is
# probably legitimate, just the manifest write isn't" — aborting the
# whole commit would lose the legitimate work, which is the opposite
# of what m46 spent its budget fixing.
_check_manifest_write_guard() {
    local manifest_path=".claude/milestones/MANIFEST.cfg"
    local sentinel="${TEKHTON_DIR:-.tekhton}/.finalize_active"

    # No staging includes the manifest → nothing to check.
    if ! git diff --cached --name-only 2>/dev/null | grep -qx "$manifest_path"; then
        return 0
    fi
    # Finalize chain is the legitimate writer.
    if [[ -f "$sentinel" ]]; then
        return 0
    fi
    warn "[manifest-guard] Refusing to commit ${manifest_path} from stage" \
         "(${STAGE_LABEL:-unknown}): file is finalize-owned. Unstaging."
    warn "[manifest-guard] If this is intentional (e.g. a milestone-authoring tool)," \
         "set TEKHTON_MANIFEST_WRITE_OVERRIDE=1 in the environment."
    if [[ "${TEKHTON_MANIFEST_WRITE_OVERRIDE:-}" = "1" ]]; then
        warn "[manifest-guard] override set — proceeding with the write"
        return 0
    fi
    git restore --staged "$manifest_path" 2>/dev/null || true
}
```

Call the helper from `_do_git_commit` immediately before the actual
`git commit` invocation.

### Goal 3 — Go-side defense-in-depth

**File:** `cmd/tekhton/run.go` (or a new internal package called from
`runAutoAdvanceLoop` / RunSingle).

Mirror the bash check in Go for the auto-advance per-iteration banner
path. After `r.RunSingle(ctx, nextReq)` returns, inspect the iteration's
final commit (via `git log -1 --format=%H` + the staged-files-in-commit
list) and emit a warning to the banner if MANIFEST.cfg was committed by
a non-finalize source.

This is purely additive observability — the bash check (Goal 2) is the
hard enforcer. The Go-side check exists so the m48-shape failure mode
shows up in the per-iteration `⚠ ...` banner that m48 introduced.

### Goal 4 — Coder prompt tightening

**File:** `prompts/coder.prompt.md`.

Add an explicit instruction in the agent's role guidance:

```markdown
### File Boundaries

The following files are managed by the finalize chain and MUST NOT be
written by the coder agent under any circumstance:

- `.claude/milestones/MANIFEST.cfg` — the milestone state manifest. The
  finalize chain (`_hook_mark_done`, `tekhton dag advance`) owns every
  write. If your milestone needs to add or modify a manifest entry,
  surface this in `## Drift Observations` so the operator can perform
  the change manually.

Writes to these files are intercepted by a pre-commit guard
(`lib/finalize_commit.sh::_check_manifest_write_guard`); the rest of
the commit will proceed but the manifest change will be unstaged with
a warning.
```

Light touch — soft prevention to complement the hard pre-commit guard.

### Goal 5 — Regression tests

**File:** `internal/finalize/orchestrator_test.go` — add
`TestOrchestrator_SetsAndClearsFinalizeActiveSentinel`:

- Construct an Orchestrator against a `t.TempDir()`.
- Run a no-op hook chain (or a minimal hook).
- Assert: during the hook chain, `.tekhton/.finalize_active` exists.
- Assert: after `Run` returns, the sentinel is gone.

**File:** `tests/test_manifest_write_guard.sh` (new, ~90 lines).
Shim-boundary integration test:

1. Set up a throwaway repo with a manifest and a `.tekhton/` dir.
2. Simulate a coder-stage commit attempt that stages MANIFEST.cfg
   (write a change directly via shell).
3. Source `lib/finalize_commit.sh` and invoke `_check_manifest_write_guard`.
4. Assert: MANIFEST.cfg is unstaged; the warning is logged to stderr;
   exit code is 0 (non-fatal).
5. Run a second scenario: plant `.tekhton/.finalize_active`,
   re-stage MANIFEST.cfg, invoke the guard, assert MANIFEST.cfg
   stays staged.
6. Run a third scenario: set `TEKHTON_MANIFEST_WRITE_OVERRIDE=1`,
   invoke the guard without the sentinel, assert MANIFEST.cfg stays
   staged AND a "override set" message is logged.

Self-skips cleanly when the Go binary isn't built — same pattern as
`tests/test_state_writer_resume_fields.sh`.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/finalize/orchestrator.go` | Modify | Write `.tekhton/.finalize_active` at hook-chain start; clear it in the deferred tail. |
| `internal/finalize/orchestrator_test.go` | Modify | Add `TestOrchestrator_SetsAndClearsFinalizeActiveSentinel`. |
| `lib/finalize_commit.sh` | Modify | Add `_check_manifest_write_guard`; call it from `_do_git_commit` before the `git commit` invocation. |
| `cmd/tekhton/run.go` | Modify | Add a defense-in-depth check in `emitAutoAdvanceCommitBanner` that surfaces `⚠ MANIFEST.cfg committed by non-finalize source` when detected. |
| `prompts/coder.prompt.md` | Modify | Add the "File Boundaries" subsection listing finalize-owned files. |
| `tests/test_manifest_write_guard.sh` | Create | Three-scenario shim-boundary test (Goal 5). |
| `docs/v4-phase5-stub.md` | Modify (optional) | Document the finalize-owned-files convention so future stage ports inherit it. |

---

## Acceptance Criteria

- [ ] `internal/finalize/orchestrator.go::Run` writes `.tekhton/.finalize_active` at the top of the hook chain. Verified by `grep -nE 'finalize_active' internal/finalize/orchestrator.go` returning matches in the file body.
- [ ] `.tekhton/.finalize_active` is cleaned up after `Run` returns. Verified by `TestOrchestrator_SetsAndClearsFinalizeActiveSentinel`.
- [ ] `lib/finalize_commit.sh` contains `_check_manifest_write_guard`. Verified by `grep -nE '_check_manifest_write_guard' lib/finalize_commit.sh` returning at least three matches (definition + call site + comment).
- [ ] `_do_git_commit` calls `_check_manifest_write_guard` before the `git commit -m` invocation. Verified by `grep -B 2 'git commit -m' lib/finalize_commit.sh` showing the guard call within 5 lines above the commit.
- [ ] A stage-time commit that stages MANIFEST.cfg without `.tekhton/.finalize_active` results in MANIFEST.cfg being unstaged AND the rest of the commit proceeding. Verified by scenario 1 of `tests/test_manifest_write_guard.sh`.
- [ ] A finalize-time commit (with the sentinel present) successfully stages MANIFEST.cfg. Verified by scenario 2 of the test.
- [ ] Setting `TEKHTON_MANIFEST_WRITE_OVERRIDE=1` bypasses the guard. Verified by scenario 3.
- [ ] `prompts/coder.prompt.md` contains a "File Boundaries" subsection mentioning MANIFEST.cfg. Verified by `grep -nE 'MANIFEST.cfg' prompts/coder.prompt.md` returning at least one match.
- [ ] The auto-advance per-iteration banner emits `⚠ MANIFEST.cfg committed by non-finalize source` when the prior iteration's HEAD commit contains a MANIFEST.cfg change and no `.finalize_active` was set during it. Verified by a unit test on the banner emitter.
- [ ] No regression in: `internal/finalize/...` Go tests, `cmd/tekhton/...` Go tests, existing `tests/test_*.sh` files that exercise `_hook_commit`.
- [ ] `shellcheck lib/finalize_commit.sh tests/test_manifest_write_guard.sh` returns zero warnings.
- [ ] `golangci-lint run ./internal/finalize/... ./cmd/tekhton/...` and `go vet ./internal/finalize/... ./cmd/tekhton/...` clean.
- [ ] Full suite passes: `bash tests/run_tests.sh` + `go test ./...`.

## Watch For

- **The sentinel cleanup MUST be in a deferred function** so that a
  panic or unexpected exit mid-finalize doesn't leave the sentinel
  set and silently legitimize a subsequent rogue commit. The Go
  `defer os.Remove(sentinelPath)` is the right shape; do NOT
  refactor the cleanup into an inline call at the end of `Run`.
- **The bash guard's "warn + unstage + proceed" behavior is
  intentional.** Aborting the whole commit when MANIFEST.cfg is
  rogue-staged would lose the legitimate stage work (the coder's
  real changes to `internal/`, etc.) and burn operator time
  recovering. The m46 / m47 / m48 arc was specifically about NOT
  losing work to silent failures. Unstaging just the offending file
  is the minimal-disruption response.
- **`TEKHTON_MANIFEST_WRITE_OVERRIDE=1` is for operator-driven
  manifest authoring** (e.g., a milestone-authoring tool, or a
  manual recovery like the b7b5e25 restore). Document it clearly
  in the warn message AND in the `pipeline.conf.example` template.
- **The pre-commit guard inspects `git diff --cached --name-only`,
  not the working tree.** That means a coder agent that writes to
  MANIFEST.cfg WITHOUT staging it (e.g., via a free-form `Bash`
  tool invocation that runs `sed -i`) will still leave the change
  in the working tree — the guard only catches the staging
  attempt. A future hardening could add a working-tree check, but
  that's larger scope and risks false positives on legitimate
  operator edits. Out of scope for m50.
- **The Go-side defense-in-depth check in `emitAutoAdvanceCommitBanner`
  is observability only**, NOT enforcement. If a future regression
  somehow bypasses the bash guard (e.g., a new code path that calls
  `git commit` directly without sourcing `lib/finalize_commit.sh`),
  the banner makes the regression visible. Don't promote it to a
  hard error; the bash guard is the contract.
- **The sentinel file lives under `.tekhton/` alongside the other
  commit-skip sentinels (m46/m48 patterns).** That co-location is
  intentional — the per-iteration reset in m48's
  `clearAutoAdvanceIterationState` already removes those sentinels,
  so the m50 sentinel will get cleaned up between auto-advance
  iterations without additional plumbing. Don't add it to a
  different directory.

## Seeds Forward

- **Generalize the finalize-owned-files concept (post-V4 polish).**
  m50 hardcodes the one file (MANIFEST.cfg) that's been observed to
  matter. A future arc could promote this to a structured list:
  `internal/finalize/owned_files.go` exports `OwnedFiles []string`,
  the bash guard reads it via `tekhton finalize owned-files --list`,
  and any future finalize-owned file (potentially `.claude/index/`,
  `.claude/dashboard/data/`, etc.) gets added in one place. Not
  required today; the one-file form is fine until a second file
  needs the same treatment.
- **Working-tree write detection.** The pre-commit guard catches
  staged writes, but a coder agent that uses `Bash` to `sed -i`
  the manifest will leave the change in the working tree even
  when not committed. A follow-up could add a working-tree
  sentinel check (compare MANIFEST.cfg's mtime or hash against a
  baseline at stage start) and warn or block. Riskier (false
  positives on legitimate operator edits) but useful as a Pro-mode
  toggle.
- **CI guard.** A `.github/workflows/` job could run the guard
  retrospectively against every push and reject PRs that
  introduce MANIFEST.cfg changes outside a finalize-tagged commit.
  Belt-and-suspenders for the V5-era when multiple developers work
  on the same branch. Not in m50 scope.
- **Drift Observation surfacing for legitimate manifest needs.**
  When a coder agent legitimately needs to add a milestone entry
  (e.g., a multi-stage refactor that surfaces a new follow-up),
  m50 says they should write to `## Drift Observations`. A future
  enhancement could auto-extract those drift observations into a
  human-reviewable `PROPOSED_MANIFEST_ADDITIONS.md` that the
  operator can apply at finalize time. Light touch; tracks well
  with the V5 "operator-in-the-loop" theme.
