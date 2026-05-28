# Coder Summary
## Status: IN PROGRESS
## What Was Implemented
(in progress)
## Root Cause (bugs only)
N/A — m28.1 is a fix milestone (Serena template + resolver fix), not a bug-fix
in the failure-report sense. Root cause of the underlying defect: the template
emitted `"python -m serena"` which fails (`No module named serena.__main__`),
and there is no resolver path for the console-script binary that Serena ships.
## Files Modified
(fill in as you go)
## Human Notes Status
No HUMAN_NOTES.md items listed in this run.
