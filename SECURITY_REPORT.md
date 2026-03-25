## Summary
This change removes a redundant guard clause from `_clamp_config_float` in `lib/config.sh` and adds a blank line separator in `lib/pipeline_order.sh`. Both changes are cosmetic/cleanup with no impact on security posture. The pre-existing `awk` interpolation of `$val` at `config.sh:120` is safe because the regex at line 116 (`^[0-9]+\.?[0-9]*$`) strictly limits `$val` to digits and an optional single dot before it reaches the `awk` command, preventing any injection.

## Findings
None

## Verdict
CLEAN
