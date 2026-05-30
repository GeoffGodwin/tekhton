// parse_coder.go — CODER_SUMMARY.md parser. Ports
// lib/dashboard_parsers.sh:_parse_coder_summary.
//
// Extracts:
//   - Status from "## Status: VALUE" inline or "## Status\nVALUE" header form
//   - File count from `## Files Created` + `## Files Modified` bullet items
//     (counts both - and * list markers; stops at the next ## heading)

package dashboard

import (
	"bufio"
	"os"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// ParseCoder reads CODER_SUMMARY.md and returns the parsed status + file
// count. Missing file → defaults (status="unknown", files_modified=0).
func (r *StatusReader) ParseCoder(path string) (proto.DashboardCoderReport, error) {
	out := proto.DashboardCoderReport{Status: "unknown"}
	data, err := os.ReadFile(path)
	if err != nil {
		return out, nil //nolint:nilerr // bash echoes "null"/unknown when file is missing
	}
	content := string(data)
	if m := statusInlineRE.FindStringSubmatch(content); len(m) > 1 {
		out.Status = strings.TrimSpace(m[1])
	} else if v := extractAfterHeader(content, statusHeaderRE); v != "" {
		out.Status = v
	}
	out.FilesModified = countFilesModified(content)
	return out, nil
}

// statusHeaderRE matches "## Status" or "# Status" on a line by itself
// (followed by the value on the next line). Lives here rather than in
// parse_intake.go because parse_coder.go is the only caller.
var statusHeaderRE = mustCompileAnchored(`(?m)^##? *Status\s*$`)

func countFilesModified(content string) int {
	scanner := bufio.NewScanner(strings.NewReader(content))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	inSection := false
	count := 0
	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimLeft(line, " \t")
		if isFilesSectionHeading(trimmed) {
			inSection = true
			continue
		}
		if inSection && strings.HasPrefix(trimmed, "##") {
			inSection = false
			continue
		}
		if !inSection {
			continue
		}
		if strings.HasPrefix(trimmed, "- ") || strings.HasPrefix(trimmed, "* ") {
			count++
		}
	}
	return count
}

// isFilesSectionHeading matches "## Files Created" / "## Files Modified" in
// either casing. Mirrors the bash awk pattern `/^## Files ([Cc]reated|[Mm]odified)/`.
func isFilesSectionHeading(trimmed string) bool {
	if !strings.HasPrefix(trimmed, "## Files ") {
		return false
	}
	rest := trimmed[len("## Files "):]
	for _, suffix := range []string{"Created", "Modified", "created", "modified"} {
		if strings.HasPrefix(rest, suffix) {
			return true
		}
	}
	return false
}
