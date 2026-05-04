# Human Action Required

The pipeline identified items that need your attention. Review each item
and check it off when addressed. The pipeline will display a banner until
all items are resolved.

## Action Items

- [x] [2026-04-25 | Source: architect] **D1 — `lib/config_defaults.sh` exceeds the 300-line ceiling with no documented exemption** `lib/config_defaults.sh` is 620 lines — more than double the "300-line ceiling" stated in CLAUDE.md's Non-Negotiable Rules. The file is pure data: `:=` default assignments and `_clamp_config_value` / `_clamp_config_float` calls, no conditional logic. The prior drift observation (2026-04-23) noted this but deferred the decision to the human owner. CLAUDE.md must resolve this gap before the file grows further. Two options: 1. **Document the exemption.** Add a note to CLAUDE.md Rule 2 (300-line ceiling) that "data-only files (no function bodies, only assignments and clamp calls) are exempt." This matches how the file actually works and requires zero code change. 2. **Domain-split the file.** Extract quota-related defaults (the most recent growth area, ~30 lines) into `lib/config_defaults_quota.sh`, sourced at the end of `config_defaults.sh`. Keeps each file under the ceiling without carving out a policy exception. Requires a small mechanical extraction. Recommendation: Option 1 (document the exemption) — the file has never contained logic, the ceiling rule's purpose is to prevent oversized function files, and splitting a data file buys no readability gain. Either way, a human must update CLAUDE.md. ---
- [ ] [2026-04-26 | Source: architect] **1. `stages/coder.sh` at 1131 lines — dedicated milestone required** The file is nearly 4× the 300-line ceiling. The coder noted this as pre-existing debt; the established pattern for extracting sub-stage orchestrators already exists (`stages/coder_prerun.sh`, `stages/coder_buildfix.sh`). This exceeds what a single pipeline run can safely address — function boundaries must be analyzed, sub-stage contracts defined, and resume/state hand-off preserved. Recommendation: Author a dedicated milestone targeting `stages/coder.sh` decomposition into sub-stage orchestrators. The milestone should enumerate the logical sub-stages (scout phase, turn-exhaustion continuation, completion gate, notes archival) and define the new file split before implementation begins. **2. Prune resolved/deferred noise from `DRIFT_LOG.md`** Observation 8 in the current drift log is meta-noise: entries about acceptance notes from prior audit review rounds. These are not architectural drift; they dilute the signal of real observations. Manual human pruning is the correct action (the drift log notes this itself). Recommendation: Human removes the "Acceptance notes in DRIFT_LOG.md" entry and any other entries that are pure process noise (not pointing to a real code or doc issue). ---
- [ ] [2026-05-04 | Source: coder] **m01 design doc — embed directive.** `.claude/milestones/m01-go-module-foundation.md`
- [ ] [2026-05-04 | Source: coder] contains a Go code snippet (`//go:embed ../../VERSION`) that is not
- [ ] [2026-05-04 | Source: coder] legal Go. The Architecture Change Proposal above resolves the
- [ ] [2026-05-04 | Source: coder] implementation; the doc itself should be updated by a future cleanup
- [ ] [2026-05-04 | Source: coder] pass to reflect the ldflags approach so future readers don't waste
- [ ] [2026-05-04 | Source: coder] time tracing the discrepancy.
- [ ] [2026-05-04 | Source: coder] **Self-host smoke vs Claude auth.** The acceptance criterion requires
- [ ] [2026-05-04 | Source: coder] `scripts/self-host-check.sh` to run `tekhton.sh --dry-run` on a fixture
- [ ] [2026-05-04 | Source: coder] task. `--dry-run` calls Claude CLI agents (intake + scout), which
- [ ] [2026-05-04 | Source: coder] requires auth. CI cannot satisfy that without a service account. I
- [ ] [2026-05-04 | Source: coder] resolved this by running the lighter `tekhton.sh --version` (which
- [ ] [2026-05-04 | Source: coder] exercises the bash entry point with `bin/tekhton` on `$PATH`) by
- [ ] [2026-05-04 | Source: coder] default, and gating the full `--dry-run` behind
- [ ] [2026-05-04 | Source: coder] `TEKHTON_SELF_HOST_DRY_RUN=1`. A human with auth can run the full
- [ ] [2026-05-04 | Source: coder] smoke; CI runs the safe subset.
