# Drift Log

## Metadata
- Last audit: 2026-04-13
- Runs since audit: 5

## Unresolved Observations
- [2026-04-14 | "M87"] `lib/init_config.sh:67` — the new `elif [[ -f "${project_dir}/DESIGN.md" ]]; then design_file="DESIGN.md"` branch emits a root-relative path into `pipeline.conf`, while the new TEKHTON_DIR default is `.tekhton/DESIGN.md`. This is logically correct for brownfield --init (the user may have a root-level DESIGN.md from --plan), but it creates an intentional divergence between the hardcoded fallback and the config_defaults.sh default. A future cleanup could unify these by checking `.tekhton/DESIGN.md` first, then `DESIGN.md`, and emitting whichever is found.
- [2026-04-14 | "M87"] `tests/run_tests.sh:36` — `DESIGN_FILE` is now exported with a `.tekhton/DESIGN.md` default. Tests that test the init-synthesize flow override this explicitly (`DESIGN_FILE="DESIGN.md"`), which works correctly. However, any test that relies on DESIGN_FILE being set but doesn't override it will now create/read design docs under `.tekhton/`, which is a behaviour change from before M87. The sweep appears complete, but this is the class of latent issue the root cleanliness test is designed to catch.

## Resolved
