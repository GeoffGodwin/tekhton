<!-- milestone-meta
id: "06"
status: "todo"
-->

# m06 (V5) — Staging Allowlist Hardening + Coder Summary Path Discipline

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | The V5 m04+m05 auto-advance run surfaced two adjacent commit-hygiene bugs the existing reliability arc didn't catch. **Bug A:** the bash staging allowlist (`lib/finalize_commit_staging.sh::_is_path_allowed`) refused to commit `.gitignore` from m05's finalize chain — m05's whole job was updating `.gitignore`, but the allowlist had no entry for `.gitignore`, so the file was reported as "not declared by the coder or pipeline bookkeeping" and the commit hook returned exit 1. The work landed in HEAD via the manual recovery commit (6b09b6f), but in the normal case this rejection silently swallows legitimate finalize-time file system updates. **Bug B:** a jr-coder agent during the same run wrote `JR_CODER_SUMMARY.md` to the repo ROOT instead of `.tekhton/JR_CODER_SUMMARY.md` (the env-contract path). The duplicate root-level file was a stray that survived the run and triggered the same staging-allowlist rejection. Both bugs are small, related, and gate every subsequent finalize commit on the operator noticing the warning — exactly the silent-cascade pattern the m41-m50 reliability arc was supposed to retire. |
| **Gap** | **Bug A:** `_pipeline_bookkeeping_globs()` at `lib/finalize_commit_staging.sh:50-66` enumerates 13 allowed prefixes/files (`.tekhton/`, `.claude/project_version.cfg`, `.claude/milestones/MANIFEST.cfg`, `.claude/milestones/m`, `VERSION`, `CHANGELOG.md`, `internal/`, `cmd/`, `tests/`, `testdata/`, `scripts/`, `docs/`, `Makefile`). `.gitignore` is absent. Any milestone whose deliverable touches `.gitignore` (m05 was the canonical case; every future sentinel-introducing milestone will hit this) gets its finalize commit silently rejected. The allowlist is a defense-in-depth check against the m48-shape rogue-write incident, but the rule it enforces — "stage only files the coder declared OR matching a known bookkeeping glob" — has `.gitignore` as a hole. **Bug B:** the jr-coder prompt at `prompts/jr_coder.prompt.md:15` instructs `Write \`{{JR_CODER_SUMMARY_FILE}}\`.`. The template engine substitutes `{{JR_CODER_SUMMARY_FILE}}` to the env value (`.tekhton/JR_CODER_SUMMARY.md` by default per `lib/artifact_defaults.sh:21`). When the env isn't populated (jr-coder invoked from a code path that doesn't load `artifact_defaults.sh`), the template substitution yields either empty string or literal `{{JR_CODER_SUMMARY_FILE}}`, and the agent improvises a path — frequently `JR_CODER_SUMMARY.md` at cwd, i.e. the repo root. No bash or Go post-stage check catches the misplaced file. |
| **m06 fills** | **Goal A:** add `.gitignore` to `_pipeline_bookkeeping_globs` in `lib/finalize_commit_staging.sh`. Audit the allowlist against the V4+V5 milestone history for any other "known but not listed" file path that a future reliability fix would naturally touch (candidates: `Dockerfile`, `.github/workflows/`, `pipeline.conf.example` updates). **Goal B:** tighten `prompts/jr_coder.prompt.md` to use the explicit absolute path string instead of the templated variable (defensive: even if env substitution fails, the path is hardcoded correct). Plus add a post-jr-coder hook in the coder stage's Go code that checks for known coder/jr summary file names written outside their canonical `.tekhton/` location and moves them with a warning. **Goal C:** regression tests for both — a bash shim-boundary test that drives a finalize commit with a `.gitignore` change and asserts the commit fires, and a Go unit test that drives the post-jr-coder hook with a misplaced file and asserts the move. |
| **Depends on** | none (independent reliability fix) |
| **Files changed** | `lib/finalize_commit_staging.sh`, `prompts/jr_coder.prompt.md`, `internal/stages/coder/orchestrator.go` (or a sibling file in the coder stage that runs the post-jr-coder hook), `tests/test_finalize_allows_gitignore.sh` (new), `internal/stages/coder/coder_summary_path_test.go` (new), `VERSION` |

---

## Design

### Sequencing note

m06 is the last reliability fix planned before the Codex audit. After
m06 ships, every silent-rejection failure mode observed across the
m41-m50 arc + V5 m04-m05 is closed. Codex provider work (V5 m07-m12 or
wherever they land) starts on a fully healed auto-advance machine.

### Goal A — Add `.gitignore` to the pipeline bookkeeping allowlist

**File:** `lib/finalize_commit_staging.sh`.

Current `_pipeline_bookkeeping_globs` body:

```bash
_pipeline_bookkeeping_globs() {
    cat <<'EOF'
.tekhton/
.claude/project_version.cfg
.claude/milestones/MANIFEST.cfg
.claude/milestones/m
VERSION
CHANGELOG.md
internal/
cmd/
tests/
testdata/
scripts/
docs/
Makefile
EOF
}
```

Add `.gitignore` alongside `VERSION`, `Makefile`, and `CHANGELOG.md` —
these are all repository-root config files the finalize chain
legitimately updates. The diff is one line:

```bash
_pipeline_bookkeeping_globs() {
    cat <<'EOF'
.tekhton/
.claude/project_version.cfg
.claude/milestones/MANIFEST.cfg
.claude/milestones/m
VERSION
CHANGELOG.md
.gitignore
internal/
cmd/
tests/
testdata/
scripts/
docs/
Makefile
EOF
}
```

The `_is_path_allowed` function does prefix-anchored matching, so
`.gitignore` matches exactly. No other code change needed.

**Audit step:** walk the V4 reliability arc's commits (m41-m50) and
the V5 m04-m05 commits to identify any other file path that was
modified by a finalize chain. Add anything that's recurring. Likely
candidates after audit:
- `.dockerignore` (if Docker support lands)
- `.github/workflows/*.yml` (CI workflow updates from reliability fixes)
- `pipeline.conf.example` (template updates when new config keys land)

If any of these surface during audit, add them. Otherwise the
`.gitignore` addition is sufficient for the observed failure mode.

### Goal B — Coder summary path discipline

**File:** `prompts/jr_coder.prompt.md`.

Current line 15:

```markdown
Write `{{JR_CODER_SUMMARY_FILE}}`.
```

Replace with an explicit-path-with-template-fallback shape:

```markdown
Write the JR coder summary to `.tekhton/JR_CODER_SUMMARY.md`
(the canonical location). The `{{JR_CODER_SUMMARY_FILE}}` template
variable resolves to the same path when set; the explicit path here
is a defensive fallback for invocations where the env didn't propagate.

If you cannot write to that location for any reason, surface the
failure in `## Drift Observations` of CODER_SUMMARY.md — do NOT
write the file at a different path.
```

Same change to `prompts/coder.prompt.md` for the parent coder agent's
own summary path (audit for parallel issue):

```markdown
Write `.tekhton/CODER_SUMMARY.md` (the canonical location). The
`{{CODER_SUMMARY_FILE}}` template variable resolves to the same path
when set.
```

**File:** `internal/stages/coder/orchestrator.go` (or a new sibling
`internal/stages/coder/path_check.go`).

Add a post-coder-invocation hook that scans for misplaced summary
files at known wrong locations and moves them to the canonical
`.tekhton/` path with a warning:

```go
// checkAndMoveMisplacedSummaries scans for coder/jr-coder summary files
// written to non-canonical locations (typically the repo root) and
// moves them to .tekhton/ with a warning. Catches the agent-side bug
// where the prompt's template variable expansion failed and the agent
// improvised a path. The hook is non-fatal — a missed summary becomes
// a Drift Observation, not a hard error.
func (o *orchestrator) checkAndMoveMisplacedSummaries() {
    candidates := []struct{ name, dest string }{
        {"CODER_SUMMARY.md", ".tekhton/CODER_SUMMARY.md"},
        {"JR_CODER_SUMMARY.md", ".tekhton/JR_CODER_SUMMARY.md"},
    }
    for _, c := range candidates {
        wrongPath := filepath.Join(o.req.ProjectDir, c.name)
        rightPath := filepath.Join(o.req.ProjectDir, c.dest)
        if _, err := os.Stat(wrongPath); err != nil {
            continue
        }
        // If the canonical file already exists, the misplaced one is a
        // stray. Delete it (preserve the canonical version).
        if _, err := os.Stat(rightPath); err == nil {
            _ = os.Remove(wrongPath)
            o.log.Warn(fmt.Sprintf("Stray %s at repo root removed (canonical version at %s)", c.name, c.dest))
            continue
        }
        // Canonical missing — move the misplaced version.
        if err := os.Rename(wrongPath, rightPath); err != nil {
            o.log.Warn(fmt.Sprintf("Failed to move misplaced %s → %s: %v", c.name, c.dest, err))
            continue
        }
        o.log.Warn(fmt.Sprintf("Misplaced %s moved to canonical %s", c.name, c.dest))
    }
}
```

Call the hook from the orchestrator's tail block (after agent
invocations complete, before stage envelope emission).

### Goal C — Regression tests

**File:** `tests/test_finalize_allows_gitignore.sh` (new, ~80 lines).
Shim-boundary test:

1. Set up a throwaway repo with `.gitignore` modified.
2. Stage a fixture CODER_SUMMARY.md that declares ONLY `internal/foo.go`
   (not `.gitignore` — simulating m05's case).
3. Source `lib/finalize_commit_staging.sh` and invoke the staging
   allowlist check for `.gitignore`.
4. Assert: `_is_path_allowed .gitignore` returns 0 (allowed).
5. Plus: drive a full `_do_git_commit` and assert it succeeds with
   `.gitignore` in the diff.

**File:** `internal/stages/coder/coder_summary_path_test.go` (new, ~120 LOC).
Three test cases for `checkAndMoveMisplacedSummaries`:

1. **Misplaced root file, canonical absent**: plant `JR_CODER_SUMMARY.md`
   at project root, no canonical file. Assert: after hook, root file
   gone, `.tekhton/JR_CODER_SUMMARY.md` exists with the original content.
2. **Misplaced root file, canonical present**: plant both. Assert: root
   file gone, canonical file unchanged.
3. **No misplaced file**: clean state. Assert: hook is a no-op,
   canonical (if present) unchanged.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `lib/finalize_commit_staging.sh` | Modify | Add `.gitignore` to `_pipeline_bookkeeping_globs` (and any others surfaced by the audit). |
| `prompts/jr_coder.prompt.md` | Modify | Explicit absolute path + defensive fallback wording for the summary write target. |
| `prompts/coder.prompt.md` | Modify | Same pattern for the parent coder's summary. |
| `internal/stages/coder/orchestrator.go` (or sibling `path_check.go`) | Modify | Add `checkAndMoveMisplacedSummaries` + call from the orchestrator tail. |
| `tests/test_finalize_allows_gitignore.sh` | Create | Shim-boundary test for Goal A. |
| `internal/stages/coder/coder_summary_path_test.go` | Create | Three-case unit test for Goal B's hook. |
| `VERSION` | Modify | Bump on close. |

---

## Acceptance Criteria

- [ ] `lib/finalize_commit_staging.sh::_pipeline_bookkeeping_globs` contains a `.gitignore` line. Verified by `grep -nE '^\.gitignore$' lib/finalize_commit_staging.sh` returning at least one match inside the heredoc.
- [ ] `_is_path_allowed .gitignore` returns 0 (allowed) when called from `lib/finalize_commit_staging.sh`'s body. Verified by `tests/test_finalize_allows_gitignore.sh`.
- [ ] A finalize commit with `.gitignore` as the only undeclared file succeeds (does not exit 1 from `_hook_commit`). Verified by the shim-boundary test driving `_do_git_commit` end-to-end.
- [ ] `prompts/jr_coder.prompt.md` instructs the agent to write to the literal path `.tekhton/JR_CODER_SUMMARY.md`. Verified by `grep -nE '\.tekhton/JR_CODER_SUMMARY\.md' prompts/jr_coder.prompt.md` returning at least one match.
- [ ] `prompts/coder.prompt.md` instructs the agent to write to the literal path `.tekhton/CODER_SUMMARY.md`. Verified by `grep -nE '\.tekhton/CODER_SUMMARY\.md' prompts/coder.prompt.md` returning at least one match.
- [ ] `internal/stages/coder/` exports (or implements) `checkAndMoveMisplacedSummaries` that detects misplaced `JR_CODER_SUMMARY.md` at repo root. Verified by `TestCheckAndMoveMisplacedSummaries_MisplacedRootCanonicalAbsent` passing.
- [ ] When both the misplaced file and the canonical file exist, the hook removes the misplaced file and preserves the canonical one. Verified by `TestCheckAndMoveMisplacedSummaries_MisplacedRootCanonicalPresent`.
- [ ] No regression in: existing `lib/finalize_*.sh` tests, `internal/stages/coder/...` tests, end-to-end auto-advance tests.
- [ ] `shellcheck tests/test_finalize_allows_gitignore.sh` clean.
- [ ] `golangci-lint run ./internal/stages/coder/...` and `go vet` clean.
- [ ] Full suite passes.

## Watch For

- **The allowlist is defense-in-depth, not the only safety check.** Adding
  `.gitignore` to the allowlist isn't the same as "anyone can write to
  `.gitignore` from anywhere." The m50 manifest write guard is the hard
  enforcer for finalize-owned files; the allowlist is a softer "did the
  coder declare this?" check. The `.gitignore` addition just stops the
  allowlist from rejecting legitimate finalize-time updates that m50's
  guard already permits (`.tekhton/.finalize_active` is set).
- **Don't widen the allowlist beyond observed-recurring files.** Resist
  the temptation to add patterns like `.*ignore` (`.dockerignore`,
  `.npmignore`, etc.). Add files when they're actually used by the
  pipeline. Each addition is a small loosening; cumulative looseness
  defeats the allowlist's purpose.
- **The post-coder path-check hook is a backstop, NOT a license for
  agents to write wherever.** The prompt change is the primary fix.
  The hook catches stray writes that slip through despite the prompt.
  Don't relax the prompt because "the hook will catch it" — both
  layers together make the system robust.
- **Move vs delete priority is intentional.** When the canonical
  file exists AND a misplaced one appears, DELETE the misplaced
  (the canonical is the authoritative version). When only the
  misplaced exists, MOVE it (preserve the agent's work). Reversed
  order silently loses real content.
- **The hook runs after every coder/jr-coder invocation, including
  rework cycles.** A 5-cycle review with 5 jr-coder reworks would
  fire the hook 5 times. Make it cheap — `os.Stat` checks first, no
  expensive operations unless a misplaced file is found.

## Seeds Forward

- **Allowlist as data.** Today `_pipeline_bookkeeping_globs` is a
  heredoc in bash. A future cleanup could promote it to a
  configuration file (`scripts/pipeline-allowlist.txt`) that both the
  bash side and the Go-side runner consult. Single source of truth.
- **Path-check hook for other artifacts.** REVIEWER_REPORT.md,
  TESTER_REPORT.md, SECURITY_REVIEW.md all have canonical `.tekhton/`
  paths and could be similarly misplaced by an agent under prompt
  expansion failure. Extending `checkAndMoveMisplacedSummaries` to
  cover them is straightforward; this milestone only addresses the
  observed cases (CODER_SUMMARY + JR_CODER_SUMMARY).
- **Prompt-time validation.** Before sending a rendered prompt to the
  agent, verify every `{{VAR}}` placeholder substituted successfully.
  Today a missing env yields empty string; agent-side improvisation
  is the result. A pre-send check that fails loudly would prevent
  this class of bug at source.
- **Telemetry on hook fire-rate.** Track how often
  `checkAndMoveMisplacedSummaries` actually catches misplaced files.
  A spike signals an upstream regression in prompt rendering or env
  propagation worth investigating.
