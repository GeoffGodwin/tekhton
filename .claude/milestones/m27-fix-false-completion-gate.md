<!-- milestone-meta
id: "27"
status: "todo"
-->

# m27 — Fix False-Completion Gate: Require Substantive Work to Mark a Milestone Done

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | An auto-advance run marked m21, m22, m24 `done` and m23 partially done while the agents shipped **zero** source files — the `[MILESTONE ✓]` commits contained only bookkeeping (manifest flip, milestone-file deletion, `.tekhton/` logs). This makes autonomous runs untrustworthy: a no-op agent produces a false completion that is indistinguishable from real work in the manifest. The whole dogfood/cutover loop depends on `done` meaning done. |
| **Gap** | The milestone-completion decision never verifies the agent produced real work. `check_milestone_acceptance` (`lib/milestone_acceptance.sh`) passes on TEST_CMD + ANALYZE_CMD alone; its "criteria" check reads `CLAUDE.md` (empty in DAG mode, so skipped) and never inspects deliverables. The per-stage completion gate (`internal/gates/completion.go:194`) passes a self-reported `Status: COMPLETE` after running only TEST_CMD — its substantive-work probe fires *only* when the status field is missing, and `completionGateFromEnv` (`cmd/tekhton/gate.go:261`) does not even wire that probe. `_files_changed` is computed (`lib/orchestrate_complete.sh:195`) but used only for telemetry. Net: tests-still-green ⇒ milestone done, regardless of whether anything was built. |
| **m27 fills** | Adds a substantive-work backstop to `check_milestone_acceptance`: a milestone in milestone-mode fails acceptance unless the working tree contains ≥1 changed/untracked file outside the pure-artifact set (`.tekhton/`, `.claude/logs/`, `.claude/milestones/`, `.claude/project_version.cfg`, `VERSION`, `CHANGELOG.md`, session dir). Nothing commits mid-milestone, so at acceptance time the working-tree diff vs HEAD is the milestone's complete output — a count of 0 is a no-op. A failed acceptance routes to the existing rework/stuck-detection path instead of finalizing, so no false `done` and no false bookkeeping commit. Gated by `MILESTONE_REQUIRE_SUBSTANTIVE_WORK` (default true) for reversibility. |
| **Depends on** | (none) |
| **Files changed** | `lib/milestone_acceptance.sh`, `internal/config/defaults.go`, `templates/pipeline.conf.example`, `tests/test_milestone_substantive_gate.sh`, `CLAUDE.md` |

---

## Design

### Goal 1 — Substantive-work backstop in milestone acceptance

New helper `_milestone_substantive_file_count` echoes the count of changed +
untracked files excluding pipeline artifacts:

```bash
{ git diff --name-only HEAD; git ls-files --others --exclude-standard; } \
  | grep -vE '^\.tekhton/|^\.claude/logs/|^\.claude/milestones/|^\.claude/project_version\.cfg$|^VERSION$|^CHANGELOG\.md$|^<session>/' \
  | grep -c '.'
```

Wired as "Automatable check 5" in `check_milestone_acceptance`, before the
final verdict: when `MILESTONE_MODE=true` and
`MILESTONE_REQUIRE_SUBSTANTIVE_WORK=true` and the count is 0 → `all_pass=false`,
emit causal event `acceptance_failed_no_substantive_work`. The orchestrate
loop's `_handle_pipeline_success` already turns an acceptance failure into a
rework retry (and Tier-2 stuck detection caps repeats), so a persistently
no-op milestone halts with a diagnosis instead of being marked done.

### Why the bash acceptance layer (not the Go completion gate)

The completion gate is the earlier, theoretically-better choke point, but
`completionGateFromEnv` ships `Substantive: nil`, so fixing it requires new
subprocess plumbing into the gate. The acceptance layer already runs at the
exact milestone success/rework branch with the full working tree available,
makes the guarantee unconditional, and is one localized, reversible change.
Failing earlier at the coder stage is a follow-up refinement (see Seeds).

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `lib/milestone_acceptance.sh` | Add + modify | `_milestone_substantive_file_count` helper + check 5 in `check_milestone_acceptance`. |
| `internal/config/defaults.go` | Modify | Default `MILESTONE_REQUIRE_SUBSTANTIVE_WORK=true`. |
| `templates/pipeline.conf.example` | Modify | Document the new key. |
| `tests/test_milestone_substantive_gate.sh` | Create | Unit test for the substantive-file probe (artifact-only=0, real/untracked≥1). |
| `CLAUDE.md` | Modify | Template-variable table entry. |

---

## Acceptance Criteria

- [ ] `tests/test_milestone_substantive_gate.sh` passes: artifact-only working-tree changes count as 0; a real tracked change and an untracked source file each count ≥1.
- [ ] With `MILESTONE_MODE=true` and only `.tekhton/`/manifest/`VERSION` changes in the tree, `check_milestone_acceptance` returns non-zero (acceptance fails).
- [ ] With one real source-file change present, `check_milestone_acceptance`'s substantive check passes (does not set `all_pass=false` on the substantive ground).
- [ ] `MILESTONE_REQUIRE_SUBSTANTIVE_WORK=false` reverts to pre-m27 behavior (substantive check skipped).
- [ ] `internal/config/defaults.go` resolves `MILESTONE_REQUIRE_SUBSTANTIVE_WORK` to `true` by default.
- [ ] `lib/milestone_acceptance.sh` passes shellcheck and stays under the 300-line ceiling.
- [ ] No regression in `go test ./...` and the bash acceptance-related tests.

## Watch For

- **Nothing commits mid-milestone:** the working-tree-vs-HEAD assumption holds because `_hook_commit` runs only in finalize. If that ever changes (per-iteration commits), the probe must compare against the milestone-start commit instead.
- **Cross-milestone leakage:** the older commit-completeness bug could leave a prior milestone's files uncommitted, inflating the count for the next milestone. That bug is being addressed separately; once finalize commits completely, HEAD is a clean milestone baseline.
- **Pure-artifact milestones:** a milestone whose only output is a version/changelog bump would be blocked — intended; use the override if such a milestone is ever legitimate.
- **Don't widen the artifact exclusion:** the `_pipeline_bookkeeping_globs` allowlist (`finalize_commit_staging.sh`) deliberately includes `internal/`, `cmd/`, `tests/` so they get committed — it is NOT a "non-work" set and must not be reused here.

## Seeds Forward

- **Coder-stage fast-fail (follow-up):** wire a `SubstantiveProbe` into `completionGateFromEnv` and require substantive work in the `COMPLETE` branch of `internal/gates/completion.go`, so a no-op fails at the coder stage instead of after a full pipeline pass.
- **Commit-completeness bug:** the sibling reliability issue (finalize commits a subset of intended files) still needs its own milestone; this milestone only stops false `done`, not partial commits.
- **Acceptance-criteria evaluation:** check 3 reading `CLAUDE.md` in DAG mode is dead; a future milestone could parse the DAG milestone file's criteria for real deliverable verification.
