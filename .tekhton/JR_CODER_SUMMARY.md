## What Was Fixed

- **`templates/pipeline.conf.example` missing PROVIDER block** — Added the
  `PROVIDER=codex,claude` default and all commented per-stage overrides
  (`PROVIDER_intake`, `PROVIDER_coder`, `PROVIDER_security`, `PROVIDER_review`,
  `PROVIDER_tester`, `PROVIDER_architect`, `PROVIDER_docs`, `PROVIDER_cleanup`)
  between the Models & Turns section and Section 3: Pipeline Behavior.
  Includes migration callout noting the m15 default change from implicit
  Claude-only to `codex,claude`. Acceptance criterion
  `grep -q 'PROVIDER=' templates/pipeline.conf.example` now passes.

- **`lib/init_config_sections.sh` missing `_emit_provider_section`** — Added
  `_emit_provider_section` function to `lib/init_config_workspace.sh` (already
  sourced by `init_config_sections.sh`, used as the overflow file to keep
  `init_config_sections.sh` at the 300-line ceiling). Added call to
  `_emit_provider_section` in `generate_sectioned_config` after
  `_emit_section_models_turns`, so `tekhton --init` now emits the PROVIDER block
  into freshly-rendered pipeline.conf files.

## Files Modified

- `templates/pipeline.conf.example`
- `lib/init_config_workspace.sh`
- `lib/init_config_sections.sh`
