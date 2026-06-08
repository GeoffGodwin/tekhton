package buildfix

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
)

// defaultErrorTailWindow is the number of non-blank lines ErrorTail
// returns. The bash version's _bf_get_error_tail uses `tail -20`; the
// window size is part of the unit-test fixture per the bash file's
// "do not change without updating tests/test_build_fix_loop.sh" comment.
// Do not change to 15 or 25 — the m39.3 loop expects exactly 20.
const defaultErrorTailWindow = 20

// nowFn is the time source for AppendReport + EmitRoutingDiagnosis. Tests
// inject a fixed clock to produce deterministic timestamps; production
// uses time.Now. Keeping it package-private avoids leaking the seam to
// callers — the m39.3 orchestrator never overrides it.
var nowFn = time.Now

// timestampFormat mirrors `date '+%Y-%m-%d %H:%M:%S'` from the bash
// helpers byte-identically.
const timestampFormat = "2006-01-02 15:04:05"

// CountErrors mirrors _bf_count_errors. Counts newline bytes in the file;
// returns 0 (no error) when the file is missing. Mirrors `wc -l` behavior
// — a file with content "a\nb\n" returns 2; "a\nb" (no trailing newline)
// returns 1. Other read errors propagate.
func CountErrors(path string) (int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	return bytes.Count(data, []byte{'\n'}), nil
}

// ErrorTail mirrors _bf_get_error_tail. Returns the last 20 non-blank
// lines (a "blank line" is any line that is empty or contains only
// whitespace), joined with '\n'. Returns "" when the file is missing or
// contains no non-blank lines. Other read errors propagate.
//
// The 20-line window is frozen by the m39.3 loop's stall-detection
// fixture; see defaultErrorTailWindow.
func ErrorTail(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	var nonBlank []string
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimFunc(line, unicode.IsSpace) == "" {
			continue
		}
		nonBlank = append(nonBlank, line)
	}
	if len(nonBlank) == 0 {
		return "", nil
	}
	start := len(nonBlank) - defaultErrorTailWindow
	if start < 0 {
		start = 0
	}
	return strings.Join(nonBlank[start:], "\n"), nil
}

// AppendReport mirrors _append_build_fix_report. Append-only writer: the
// first call (when path doesn't exist) writes the header heredoc; every
// call appends one `## Attempt N` section. The schema is operator-visible
// — downstream parsers grep for the field labels.
//
// The bash version silently returns when the directory can't be created
// (`mkdir -p ... || return 0`); the Go port surfaces that error so
// callers can decide whether to log or swallow.
func AppendReport(path string, r AttemptReport) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	// Open append-create so multiple invocations grow the file rather than
	// overwriting it. The header is written only when the file does NOT
	// pre-exist — matches the bash `if [[ ! -f "$file" ]]` guard.
	needHeader := false
	if _, err := os.Stat(path); err != nil {
		if !os.IsNotExist(err) {
			return err
		}
		needHeader = true
	}

	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()

	var buf bytes.Buffer
	if needHeader {
		fmt.Fprintf(&buf, "# Build-Fix Report — %s\n", nowFn().Format(timestampFormat))
		buf.WriteString("\n")
		buf.WriteString("Per-attempt history of the coder-stage build-fix continuation loop (M128).\n")
		buf.WriteString("Each attempt records the adaptive turn budget, the agent's terminal class,\n")
		buf.WriteString("the post-attempt build-gate result, the progress signal vs. the prior\n")
		buf.WriteString("attempt, and the M127 routing classification at loop entry.\n")
	}
	// Leading blank line + section. Matches the bash heredoc that starts
	// with an empty line before "## Attempt N".
	buf.WriteString("\n")
	fmt.Fprintf(&buf, "## Attempt %d\n", r.Attempt)
	fmt.Fprintf(&buf, "- Turn budget: %d\n", r.Budget)
	fmt.Fprintf(&buf, "- Terminal class: %s\n", r.TerminalClass)
	fmt.Fprintf(&buf, "- Gate result: %s\n", r.GateResult)
	fmt.Fprintf(&buf, "- Progress signal: %s\n", r.ProgressSignal)
	fmt.Fprintf(&buf, "- Error-count delta: %s\n", r.ErrorCountDelta)
	fmt.Fprintf(&buf, "- M127 classification: %s\n", r.Classification)

	_, err = f.Write(buf.Bytes())
	return err
}

// EmitRoutingDiagnosis mirrors _bf_emit_routing_diagnosis. Writes
// BUILD_ROUTING_DIAGNOSIS.md given the pipe-delimited stats stream
// produced by classify_build_errors_with_stats (or its Go equivalent
// internal/errors.ClassifyWithStats followed by .FormatStatsLegacy()).
//
// The first record supplies the header stats (TotalLines, TotalMatched,
// UnmatchedLines). The top three non-empty records render as bullet
// lines under "## Top Diagnoses"; if statsText is empty, a
// "(no recognized signatures)" placeholder renders instead.
//
// The 8-pipe-field format is operator-visible vocabulary — preserve all
// eight even though the markdown shows only four (category, safety,
// count, diagnosis).
func EmitRoutingDiagnosis(outputPath, statsText string) error {
	if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
		return err
	}

	var totalMatched, totalLines, unmatchedLines int
	if statsText != "" {
		fields := splitStatsLine(firstLine(statsText))
		if len(fields) >= 8 {
			totalMatched = atoiSafe(fields[5])
			totalLines = atoiSafe(fields[6])
			unmatchedLines = atoiSafe(fields[7])
		}
	}

	var buf bytes.Buffer
	fmt.Fprintf(&buf, "# Build Routing Diagnosis — %s\n", nowFn().Format(timestampFormat))
	buf.WriteString("\n")
	buf.WriteString("## Routing Decision\n")
	buf.WriteString("mixed_uncertain — both code and non-code signals present.\n")
	buf.WriteString("\n")
	buf.WriteString("## Line Stats\n")
	fmt.Fprintf(&buf, "- considered: %d\n", totalLines)
	fmt.Fprintf(&buf, "- matched: %d\n", totalMatched)
	fmt.Fprintf(&buf, "- unmatched: %d\n", unmatchedLines)
	buf.WriteString("\n")
	buf.WriteString("## Top Diagnoses\n")
	if statsText == "" {
		buf.WriteString("- (no recognized signatures)\n")
	} else {
		emitted := 0
		for _, rec := range strings.Split(statsText, "\n") {
			if rec == "" {
				continue
			}
			fields := splitStatsLine(rec)
			if len(fields) < 5 {
				continue
			}
			fmt.Fprintf(&buf, "- %s (%s) ×%s: %s\n", fields[0], fields[1], fields[4], fields[3])
			emitted++
			if emitted >= 3 {
				break
			}
		}
		if emitted == 0 {
			buf.WriteString("- (no recognized signatures)\n")
		}
	}

	return os.WriteFile(outputPath, buf.Bytes(), 0o644)
}

// firstLine returns the first '\n'-delimited line of s, without the
// newline. If s contains no newline, returns s unchanged.
func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// splitStatsLine splits a single record on '|'. The bash version uses
// `IFS='|' read -r ...` which truncates / pads to the read variable
// count; here we return the raw fields so the caller can length-check.
func splitStatsLine(rec string) []string {
	return strings.Split(rec, "|")
}

// atoiSafe converts s to int, returning 0 on parse error. Mirrors bash's
// arithmetic context which treats non-numeric tokens as 0.
func atoiSafe(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	n := 0
	negative := false
	if s[0] == '-' {
		negative = true
		s = s[1:]
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	if negative {
		n = -n
	}
	return n
}
