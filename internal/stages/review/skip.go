package review

import (
	"bytes"
	"os/exec"
	"regexp"
	"strconv"
)

// sizeSkipReason carries the metadata the stage echoes when the diff-size
// skip-heuristic fires. Both fields are stringified at the StageResult
// metadata boundary, so they live as strings here too.
type sizeSkipReason struct {
	Threshold string
	DiffLines string
}

// shouldSkipPolish ports the polish-mode reviewer skip from
// stages/review.sh:16-22. The bash version probes for the optional
// `should_skip_review_for_polish` function via `command -v`; if absent the
// branch is dead. No Go-side detector exists yet (audit per the Watch For),
// so this stub mirrors bash semantics: the function is absent ⇒ skip never
// triggers. A follow-up milestone can land the Go-native polish detector
// here without changing the call site.
func shouldSkipPolish(_ *config) bool {
	return false
}

// shouldSkipBySize ports the M48 diff-size review threshold from
// stages/review.sh:24-36. Skip iff:
//   - REVIEW_SKIP_THRESHOLD > 0
//   - MILESTONE_MODE != "true" (milestones always get a full review)
//   - git diff --stat HEAD insertions+deletions < threshold
//
// The bash `git diff --stat HEAD | tail -1 | grep -oE ... | paste -sd+ | bc`
// pipeline is replaced with a regex pass over the stat output.
func shouldSkipBySize(cfg *config) (sizeSkipReason, bool) {
	if cfg.ReviewSkipThreshold <= 0 {
		return sizeSkipReason{}, false
	}
	if cfg.MilestoneMode {
		return sizeSkipReason{}, false
	}
	if cfg.diffStatTotal == nil {
		return sizeSkipReason{}, false
	}
	diffLines, err := cfg.diffStatTotal(cfg.ProjectDir)
	if err != nil {
		return sizeSkipReason{}, false
	}
	if diffLines <= 0 {
		return sizeSkipReason{}, false
	}
	if diffLines >= cfg.ReviewSkipThreshold {
		return sizeSkipReason{}, false
	}
	return sizeSkipReason{
		Threshold: strconv.Itoa(cfg.ReviewSkipThreshold),
		DiffLines: strconv.Itoa(diffLines),
	}, true
}

// diffStatTotalRE captures the integer that precedes each occurrence of
// "insertion" or "deletion" in the `git diff --stat HEAD` summary line.
var diffStatTotalRE = regexp.MustCompile(`(\d+)\s+(?:insertion|deletion)`)

// gitDiffStatTotal sums insertions+deletions in `git diff --stat HEAD`.
// Returns 0 when git is absent or the diff is empty.
func gitDiffStatTotal(projectDir string) (int, error) {
	cmd := exec.Command("git", "diff", "--stat", "HEAD")
	if projectDir != "" {
		cmd.Dir = projectDir
	}
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		return 0, err
	}
	total := 0
	for _, m := range diffStatTotalRE.FindAllSubmatch(out.Bytes(), -1) {
		n, err := strconv.Atoi(string(m[1]))
		if err != nil {
			continue
		}
		total += n
	}
	return total, nil
}
