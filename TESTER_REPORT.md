## Planned Tests
- [x] `tests/test_human_mode_state_resume.sh` — add Phase 12: crash-resume with [~] note; pick_next_note skips claimed notes
- [x] `tests/test_human_mode_resolve_notes_edge.sh` — verify Phase 2 covers HUMAN_MODE=true + empty CURRENT_NOTE_LINE + non-zero exit (gap 2 audit)
- [x] `tests/test_human_mode_crash_resume.sh` — exec-resume with [~] note: guard skips pick_next_note, uses CURRENT_NOTE_LINE from env
- [x] `tests/test_m34_data_fidelity.sh` — M34: per-stage stages JSON, run_type classification, computed totals, _parse_intake_report, _parse_coder_summary

## Test Run Results
Passed: 195  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_human_mode_state_resume.sh`
- [x] `tests/test_human_mode_crash_resume.sh`
- [x] `tests/test_m34_data_fidelity.sh`
