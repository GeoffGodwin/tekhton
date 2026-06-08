# Build-Fix Report — <TIMESTAMP>

Per-attempt history of the coder-stage build-fix continuation loop (M128).
Each attempt records the adaptive turn budget, the agent's terminal class,
the post-attempt build-gate result, the progress signal vs. the prior
attempt, and the M127 routing classification at loop entry.

## Attempt 1
- Turn budget: 27
- Terminal class: max_turns
- Gate result: fail
- Progress signal: improved
- Error-count delta: 12→5
- M127 classification: code_dominant

## Attempt 2
- Turn budget: 40
- Terminal class: success
- Gate result: pass
- Progress signal: improved
- Error-count delta: 5→0
- M127 classification: code_dominant

## Attempt 3
- Turn budget: 54
- Terminal class: max_turns
- Gate result: fail
- Progress signal: unchanged
- Error-count delta: 0→0
- M127 classification: mixed_uncertain
