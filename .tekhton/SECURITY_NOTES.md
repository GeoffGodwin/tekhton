# Security Notes

Generated: 2026-04-16 16:57:09

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A03] [stages/coder_prerun.sh:67,117] fixable:no — `bash -c "${TEST_CMD}"` executes a config-supplied string directly in a subshell. If `pipeline.conf` is writable by an untrusted party, `TEST_CMD` could contain arbitrary shell code. This is the established pattern throughout the codebase (identical call sites in `milestone_acceptance.sh`, `test_baseline.sh`, etc.) and the blast radius is bounded to the local project directory; no new risk is introduced by M92.
