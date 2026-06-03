# Security Notes

Generated: 2026-06-03 15:37:36

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A05] [tests/test_wedge_audit_m35.sh:52] fixable:yes — Fixed-path temp file `/tmp/wedge_audit_m35.out` used without `mktemp`. On a shared system a local attacker could pre-create a symlink at that path to redirect test output to an arbitrary file owned by the running user. Also causes parallel CI runs to race on the same path. Fix: replace with a `mktemp`-generated path (following the `WORK=$(mktemp -d)` pattern in `tests/test_security_parity.sh:73`) and remove in an EXIT trap. Affects lines 52, 67, and 87.
- [LOW] [category:A03] [testdata/fake_security_agent.sh:52-54] fixable:yes — Counter value read from disk (`cat -- "$counter_file"`) is fed directly into bash arithmetic (`n=$(( n + 1 ))`). A malicious actor who can pre-create the counter file with content like `a[$(cmd)]` could achieve code execution in bash's arithmetic context. Exploitability is negligible in practice — the counter file lives inside a `mktemp`-controlled directory created by the test harness — but the pattern is unsafe by construction. Fix: strip non-digits before the expansion: `n="${n//[^0-9]/}"; n=$(( ${n:-0} + 1 ))`.
