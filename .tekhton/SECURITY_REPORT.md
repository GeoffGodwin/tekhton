## Summary
m35.3 is a pure integration-cleanup milestone: no production logic changed. The deliverables are a wedge-audit ban block in `scripts/wedge-audit-companions.sh`, two new test scripts, a fake supervisor binary in `testdata/`, nine baseline files, and documentation/version updates. There is no authentication, cryptography, network I/O, or user-input handling in any of the changed files. Two low-severity shell-scripting hygiene issues were found in test-only files; neither is exploitable outside a shared local development environment and neither blocks the pipeline.

## Findings
- [LOW] [category:A05] [tests/test_wedge_audit_m35.sh:52] fixable:yes — Fixed-path temp file `/tmp/wedge_audit_m35.out` used without `mktemp`. On a shared system a local attacker could pre-create a symlink at that path, causing the test to overwrite an arbitrary file owned by the running user. Mitigate by replacing the three references (lines 52, 67, 87) with a `mktemp`-generated path stored in a variable and cleaned up on exit.
- [LOW] [category:A03] [testdata/fake_security_agent.sh:54] fixable:yes — Counter value read from disk (`cat -- "$counter_file"`) is used directly in bash arithmetic expansion (`n=$(( n + 1 ))`). If a malicious actor pre-created the counter file with a value like `$(cmd)`, bash's arithmetic context would execute it. In practice the file is only ever written by this same script (always an integer) inside a `mktemp`-created temp directory controlled by the test harness, so real exploitability is negligible. Mitigate by stripping non-numeric content before the arithmetic: `n="${n//[^0-9]/}"; n=$(( n + 1 ))`.

## Verdict
FINDINGS_PRESENT
