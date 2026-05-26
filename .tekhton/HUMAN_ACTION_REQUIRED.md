# Human Action Required

The pipeline identified items that need your attention. Review each item
and check it off when addressed. The pipeline will display a banner until
all items are resolved.

## Action Items

- [x] [2026-04-25 | Source: architect] **D1 — `lib/config_defaults.sh` exceeds the 300-line ceiling with no documented exemption** `lib/config_defaults.sh` is 620 lines — more than double the "300-line ceiling" stated in CLAUDE.md's Non-Negotiable Rules. The file is pure data: `:=` default assignments and `_clamp_config_value` / `_clamp_config_float` calls, no conditional logic. The prior drift observation (2026-04-23) noted this but deferred the decision to the human owner. CLAUDE.md must resolve this gap before the file grows further. Two options: 1. **Document the exemption.** Add a note to CLAUDE.md Rule 2 (300-line ceiling) that "data-only files (no function bodies, only assignments and clamp calls) are exempt." This matches how the file actually works and requires zero code change. 2. **Domain-split the file.** Extract quota-related defaults (the most recent growth area, ~30 lines) into `lib/config_defaults_quota.sh`, sourced at the end of `config_defaults.sh`. Keeps each file under the ceiling without carving out a policy exception. Requires a small mechanical extraction. Recommendation: Option 1 (document the exemption) — the file has never contained logic, the ceiling rule's purpose is to prevent oversized function files, and splitting a data file buys no readability gain. Either way, a human must update CLAUDE.md.
- [x] [2026-05-07 | Source: architect] Structured objects (multi-field records, envelopes) → JSON. Resolved 2026-05-17 in `DESIGN_v4.md §Architecture Target → Output Format Conventions`.
- [x] [2026-05-07 | Source: architect] List outputs (IDs, file paths, one-thing-per-line) → bare newline. Resolved 2026-05-17 in `DESIGN_v4.md §Architecture Target → Output Format Conventions`.
- [x] [2026-05-07 | Source: architect] Pipe-delimited rows → migrate toward `--json` flag on the corresponding subcommand over time. Resolved 2026-05-17 in `DESIGN_v4.md §Architecture Target → Output Format Conventions` — pipe form frozen at existing seams; new tooling reads `--json`.
