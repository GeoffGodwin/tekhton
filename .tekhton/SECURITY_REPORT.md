## Summary

m35.3 is a lightweight cleanup milestone: wedge-audit ban blocks for deleted security bash files/functions, regression tests for those bans, a security parity gate, documentation, and a VERSION bump. There is no user-facing attack surface, no authentication or cryptography code, no network communication, and no production shell path changed. All new security-relevant code is confined to test infrastructure (`tests/`, `testdata/`, `scripts/`). Two LOW findings exist in that test infrastructure; neither is reachable from the production pipeline.

## Findings

- [LOW] [category:A03] [tests/test_wedge_audit_m35.sh:52] fixable:yes — Predictable temp file `/tmp/wedge_audit_m35.out` used without `mktemp`. On a shared-runner CI environment an attacker with write access to `/tmp` could pre-create a symlink at that path to redirect audit output to an arbitrary file. Also causes parallel CI runs to race on the same path. Fix: follow the pattern in `tests/test_security_parity.sh:73` — use `AUDIT_OUT=$(mktemp)` with an EXIT trap; update references on lines 52, 55, 59, 67, 71, 75, and 87.
- [LOW] [category:A03] [testdata/fake_security_agent.sh:52-54] fixable:yes — Counter file value read from disk with `cat` is fed directly into bash arithmetic expansion `$(( n + 1 ))`. Bash arithmetic evaluates command substitutions (e.g. `a[$(cmd)]`), so a pre-created counter file containing such an expression would execute arbitrary commands. Exploitability is negligible in practice — the counter file lives inside a `mktemp -d` directory created by the test harness — but the pattern is unsafe by construction. Fix: strip non-digits before the expansion: `n="${n//[^0-9]/}"; n=$(( ${n:-0} + 1 ))`.

## Verdict

FINDINGS_PRESENT
