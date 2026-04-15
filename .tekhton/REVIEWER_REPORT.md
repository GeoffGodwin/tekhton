# Reviewer Report — M87: Test Harness TEKHTON_DIR Parity

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `tests/test_tekhton_dir_root_cleanliness.sh` hardcodes the literal string `.tekhton/` in its pattern check rather than using a dynamic `${TEKHTON_DIR}` reference. If TEKHTON_DIR is ever changed to a non-default value, the test would produce false failures. Low probability in practice, but the fragility is worth noting.
- CODER_SUMMARY.md was deleted (old M86 content) but not regenerated for M87. The review proceeded from git diff and the milestone spec. Not a code defect, but the missing summary is a process gap.

## Coverage Gaps
- None

## ACP Verdicts
None — no ACP section in CODER_SUMMARY.

## Drift Observations
- `lib/init_config.sh:67` — the new `elif [[ -f "${project_dir}/DESIGN.md" ]]; then design_file="DESIGN.md"` branch emits a root-relative path into `pipeline.conf`, while the new TEKHTON_DIR default is `.tekhton/DESIGN.md`. This is logically correct for brownfield --init (the user may have a root-level DESIGN.md from --plan), but it creates an intentional divergence between the hardcoded fallback and the config_defaults.sh default. A future cleanup could unify these by checking `.tekhton/DESIGN.md` first, then `DESIGN.md`, and emitting whichever is found.
- `tests/run_tests.sh:36` — `DESIGN_FILE` is now exported with a `.tekhton/DESIGN.md` default. Tests that test the init-synthesize flow override this explicitly (`DESIGN_FILE="DESIGN.md"`), which works correctly. However, any test that relies on DESIGN_FILE being set but doesn't override it will now create/read design docs under `.tekhton/`, which is a behaviour change from before M87. The sweep appears complete, but this is the class of latent issue the root cleanliness test is designed to catch.
