// Package tester provides the pure helpers used by the tester stage and its
// sub-stages (TDD pre-flight, continuation, fix, validation). Lands as part
// of m38.1; the main stage port follows in m38.6.
package tester

import (
	"bufio"
	"os"
	"regexp"
	"strconv"
	"strings"
)

// ParseMode controls how ParseTesterTiming merges parsed values into a
// running TesterTiming. Replace overwrites existing fields; Accumulate adds
// to running totals (used by the turn-exhaustion continuation loop in m38.3).
type ParseMode int

const (
	// ParseModeReplace overwrites fields with parsed values.
	ParseModeReplace ParseMode = iota
	// ParseModeAccumulate adds parsed values to existing running totals.
	ParseModeAccumulate
)

// TesterTiming carries the self-reported tester timing fields parsed from
// the ## Timing section of TESTER_REPORT.md. A field value of -1 means the
// field has not been set — this sentinel matches the bash
// _TESTER_TIMING_* globals and is preserved for round-trip parity with
// anything that reads the JSON envelope downstream.
type TesterTiming struct {
	ExecCount    int
	ExecApproxS  int
	FilesWritten int
	WritingS     int
}

// ZeroTiming returns a TesterTiming with all four fields at -1.
// Mirrors the bash globals' initial state in stages/tester_timing.sh.
func ZeroTiming() TesterTiming {
	return TesterTiming{ExecCount: -1, ExecApproxS: -1, FilesWritten: -1, WritingS: -1}
}

// Regex shapes mirror stages/tester_timing.sh:36-38 exactly. The "i" prefix
// on the bash `grep -oiE` translates to (?i) here; `tail -1` on each parsed
// field translates to "pick the last match" in ParseTesterTiming.
var (
	execCountRe    = regexp.MustCompile(`(?i)Test executions:\s*([0-9]+)`)
	execTimeRe     = regexp.MustCompile(`(?i)Approximate total test execution time:\s*~?([0-9]+)`)
	filesWrittenRe = regexp.MustCompile(`(?i)Test files written:\s*([0-9]+)`)
)

// ParseTesterTiming reads the ## Timing section of reportPath and returns
// the populated TesterTiming. Missing file or missing section returns the
// zero-sentinel struct (all -1). Numeric fields validate as integers;
// unparseable values stay at -1.
//
// Mode controls whether fields replace (default) or accumulate onto a
// running total. Accumulate is for continuations — the m38.3 continuation
// loop will call this once per resume so per-continuation counts add onto
// the running total.
//
// Behavior mirrors stages/tester_timing.sh::_parse_tester_timing
// byte-for-byte, including the "pick the last match" semantics
// (`tail -1` in bash) for repeated fields.
func ParseTesterTiming(reportPath string, mode ParseMode) TesterTiming {
	return ZeroTiming().Merge(parseFromFile(reportPath), mode)
}

// MergeTimingFromFile is like ParseTesterTiming but starts from an existing
// running total rather than the zero sentinel. Used by callers that thread
// timing through multiple continuations.
func MergeTimingFromFile(running TesterTiming, reportPath string, mode ParseMode) TesterTiming {
	return running.Merge(parseFromFile(reportPath), mode)
}

// Merge combines parsed timing into the receiver according to mode.
// Replace overwrites only fields that were parsed (other fields stay as-is).
// Accumulate sums parsed values into the receiver, treating a -1 running
// total as "unset" and using the parsed value directly.
//
// Bash semantics (stages/tester_timing.sh:45-73):
//   - Accumulate: if running == -1 and parsed is set, replace; else add.
//   - Replace:    if parsed is set, overwrite; else leave running as-is.
func (t TesterTiming) Merge(other TesterTiming, mode ParseMode) TesterTiming {
	out := t
	if mode == ParseModeAccumulate {
		out.ExecCount = mergeAccumulate(out.ExecCount, other.ExecCount)
		out.ExecApproxS = mergeAccumulate(out.ExecApproxS, other.ExecApproxS)
		out.FilesWritten = mergeAccumulate(out.FilesWritten, other.FilesWritten)
		return out
	}
	if other.ExecCount >= 0 {
		out.ExecCount = other.ExecCount
	}
	if other.ExecApproxS >= 0 {
		out.ExecApproxS = other.ExecApproxS
	}
	if other.FilesWritten >= 0 {
		out.FilesWritten = other.FilesWritten
	}
	return out
}

func mergeAccumulate(running, parsed int) int {
	if parsed < 0 {
		return running
	}
	if running < 0 {
		return parsed
	}
	return running + parsed
}

// ComputeWritingTime returns the writing-time estimate (agent duration
// minus reported execution time) clamped to zero. Returns -1 when either
// agentDuration or timing.ExecApproxS is non-positive — matching the bash
// `_compute_tester_writing_time` guard at stages/tester_timing.sh:81.
func ComputeWritingTime(agentDuration int, timing TesterTiming) int {
	if timing.ExecApproxS <= 0 || agentDuration <= 0 {
		return -1
	}
	writingS := agentDuration - timing.ExecApproxS
	if writingS < 0 {
		writingS = 0
	}
	return writingS
}

// parseFromFile reads the ## Timing section of the report and returns a
// TesterTiming with whatever was parsed. Returns ZeroTiming() on missing
// file, missing section, or unparseable contents.
func parseFromFile(reportPath string) TesterTiming {
	out := ZeroTiming()
	if reportPath == "" {
		return out
	}
	f, err := os.Open(reportPath)
	if err != nil {
		return out
	}
	defer f.Close()

	var block strings.Builder
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1<<16), 1<<24)
	inSection := false
	for scanner.Scan() {
		line := scanner.Text()
		if !inSection {
			if line == "## Timing" {
				inSection = true
				block.WriteString(line)
				block.WriteByte('\n')
			}
			continue
		}
		block.WriteString(line)
		block.WriteByte('\n')
	}
	if !inSection {
		return out
	}

	text := block.String()
	if v, ok := lastIntMatch(execCountRe, text); ok {
		out.ExecCount = v
	}
	if v, ok := lastIntMatch(execTimeRe, text); ok {
		out.ExecApproxS = v
	}
	if v, ok := lastIntMatch(filesWrittenRe, text); ok {
		out.FilesWritten = v
	}
	return out
}

// lastIntMatch picks the last match of re in text and returns its captured
// integer. Mirrors the bash `... | tail -1` pipeline. Returns (-1, false)
// when there is no match or when the captured value is not a non-negative
// integer.
func lastIntMatch(re *regexp.Regexp, text string) (int, bool) {
	matches := re.FindAllStringSubmatch(text, -1)
	if len(matches) == 0 {
		return -1, false
	}
	last := matches[len(matches)-1]
	if len(last) < 2 {
		return -1, false
	}
	n, err := strconv.Atoi(last[1])
	if err != nil || n < 0 {
		return -1, false
	}
	return n, true
}
