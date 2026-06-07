package tester

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// failureMarkerRe mirrors the bash regex in
// stages/tester_fix.sh::_smart_truncate_test_output line 31. Matches any
// line containing one of the common test-failure markers.
var failureMarkerRe = regexp.MustCompile(
	`(FAIL|FAILED|ERROR|AssertionError|TypeError|ReferenceError|SyntaxError|CompilationError|assert|expected|unexpected)`)

// SmartTruncateTestOutput extracts failure-relevant lines from raw test
// output. Splits at failure markers (FAIL, ERROR, AssertionError, etc.),
// keeps first 5 + last 5 lines per block joined by "\n---\n", caps at
// limit chars. When no failure markers match, falls back to the last 80
// lines of input.
//
// Byte-identical to stages/tester_fix.sh::_smart_truncate_test_output
// for inputs that round-trip cleanly through bufio.Scanner.
func SmartTruncateTestOutput(output string, limit int) string {
	if output == "" {
		return ""
	}
	if limit <= 0 {
		limit = DefaultFixOutputLimit
	}

	var result strings.Builder
	var block strings.Builder
	inBlock := false

	scanner := bufio.NewScanner(strings.NewReader(output))
	scanner.Buffer(make([]byte, 1<<16), 1<<24)
	for scanner.Scan() {
		line := scanner.Text()
		if failureMarkerRe.MatchString(line) {
			if inBlock && block.Len() > 0 {
				result.WriteString(truncateBlock(block.String()))
				result.WriteString("\n---\n")
			}
			block.Reset()
			block.WriteString(line)
			block.WriteByte('\n')
			inBlock = true
			continue
		}
		if inBlock {
			block.WriteString(line)
			block.WriteByte('\n')
		}
	}
	if block.Len() > 0 {
		result.WriteString(truncateBlock(block.String()))
	}

	out := result.String()
	if out == "" {
		// Fall back to tail -80 of input
		out = tailLines(output, 80)
	}
	if len(out) > limit {
		out = out[:limit] + "\n... [truncated at " + intToString(limit) + " chars]"
	}
	return out
}

// truncateBlock keeps the first 5 and last 5 lines of a failure block
// joined with a "... [N lines omitted]" marker. Blocks ≤10 lines are
// returned verbatim. Mirrors stages/tester_fix.sh::_truncate_block.
func truncateBlock(block string) string {
	if block == "" {
		return ""
	}
	// Count newlines the same way `wc -l` does (bash uses wc -l on the
	// block, which counts lines terminated by '\n').
	count := strings.Count(block, "\n")
	if count <= 10 {
		return block
	}

	lines := strings.Split(block, "\n")
	// The bash `head -5` / `tail -5` operates on lines as printed; with
	// trailing newline stripped by `printf '%s'` we have count+1 fields
	// from Split, where the last is empty. Use count as the line ceiling.
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) <= 10 {
		return block
	}
	head := strings.Join(lines[:5], "\n")
	tail := strings.Join(lines[len(lines)-5:], "\n")
	omitted := len(lines) - 10
	return head + "\n  ... [" + intToString(omitted) + " lines omitted]\n" + tail
}

// tailLines returns the last n lines of body. When body has fewer than n
// lines, returns body unchanged.
func tailLines(body string, n int) string {
	if body == "" || n <= 0 {
		return ""
	}
	lines := strings.Split(body, "\n")
	if len(lines) <= n {
		return body
	}
	return strings.Join(lines[len(lines)-n:], "\n")
}

// intToString is a small fmt-free integer printer. Used by the
// truncation hot path to avoid a fmt.Sprintf allocation per block.
func intToString(n int) string {
	return strings.TrimSpace(fmt.Sprintf("%d", n))
}

// writeFixPromptTmp materializes the rendered prompt to disk so the
// supervisor can pass it via --prompt-file. The cleanup closure removes
// the temp file when the caller is done.
func writeFixPromptTmp(content string) (string, func(), error) {
	f, err := os.CreateTemp("", "tekhton-tester-fix-prompt-*.md")
	if err != nil {
		return "", func() {}, err
	}
	if _, err := f.WriteString(content); err != nil {
		_ = f.Close()
		_ = os.Remove(f.Name())
		return "", func() {}, err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(f.Name())
		return "", func() {}, err
	}
	return f.Name(), func() { _ = os.Remove(f.Name()) }, nil
}

// readCoderSummaryFiles parses the file paths from the CODER_SUMMARY
// file's "## Files Modified" / "## Files Created" sections. Ported from
// the security helper to avoid an inter-package dep cycle. Mirrors
// lib/indexer_helpers.sh::extract_files_from_coder_summary semantics.
func readCoderSummaryFiles(path string) ([]string, error) {
	f, err := os.Open(filepath.Clean(path))
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var out []string
	in := false
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<16), 1<<24)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "## Files Modified") ||
			strings.HasPrefix(line, "## Files Created") {
			in = true
			continue
		}
		if in && strings.HasPrefix(line, "##") {
			break
		}
		if !in {
			continue
		}
		cleaned := cleanCoderSummaryBullet(line)
		if cleaned == "" || cleaned == "None" || strings.HasPrefix(cleaned, "(fill") {
			continue
		}
		out = append(out, cleaned)
	}
	return out, sc.Err()
}

// cleanCoderSummaryBullet strips the leading "- " bullet, surrounding
// backticks, and trailing annotations from a coder-summary file row.
func cleanCoderSummaryBullet(line string) string {
	cleaned := line
	if i := strings.Index(cleaned, "- "); i >= 0 {
		cleaned = cleaned[i+2:]
	} else {
		return ""
	}
	cleaned = strings.TrimPrefix(cleaned, "`")
	if i := strings.Index(cleaned, "`"); i >= 0 {
		cleaned = cleaned[:i]
	}
	if i := strings.Index(cleaned, " — "); i >= 0 {
		cleaned = cleaned[:i]
	}
	if i := strings.Index(cleaned, " "); i >= 0 {
		cleaned = cleaned[:i]
	}
	return strings.TrimSpace(cleaned)
}
