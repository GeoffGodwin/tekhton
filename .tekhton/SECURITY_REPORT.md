## Summary
M90 fixes two bugs in `--auto-advance`: adding an optional bare-integer CLI argument (validated with `^[0-9]+$` regex before use) and introducing an in-memory session counter (`_AA_SESSION_ADVANCES`) that is explicitly initialized to `0` and only modified via integer arithmetic. All changes are confined to argument parsing, integer arithmetic, and state-file lifecycle management in four shell scripts and two test files, plus two doc updates. No authentication, cryptography, network communication, or external user-data handling is involved. The overall security posture is sound.

## Findings
None

## Verdict
CLEAN
