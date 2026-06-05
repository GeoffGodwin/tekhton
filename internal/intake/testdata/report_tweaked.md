# Intake Report

## Verdict
TWEAKED

## Confidence
80

## Reasoning
Original task referred to "the parser" ambiguously — clarified to
`internal/intake/helpers.go`. Acceptance criteria gained measurable thresholds.

## Tweaked Content
# m99.9 — Test Milestone (PM-tweaked)

## Overview
The intake helpers port covered the per-call helpers but missed the
verdict-routing surface. This sub-milestone adds the missing methods.

## Acceptance Criteria
- [ ] `ParseVerdict` returns one of PASS / TWEAKED / SPLIT_RECOMMENDED / NEEDS_CLARITY.
- [ ] `ApplyTweakMilestone` writes via atomic mv + backup.
- [ ] `AddPMMetadata` round-trips through ApplyTweakMilestone.

## Questions
(none)
