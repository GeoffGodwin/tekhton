package security

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Finding is one row from SECURITY_REPORT.md's `## Findings` section.
type Finding struct {
	Severity    Severity
	Fixable     string // "yes" | "no" | "unknown"
	Description string
}

// severityRE matches the [SEVERITY] token in a finding row. Mirrors the bash
// `grep -oE '\[(CRITICAL|HIGH|MEDIUM|LOW)\]'`.
var severityRE = regexp.MustCompile(`\[(CRITICAL|HIGH|MEDIUM|LOW)\]`)

// fixableRE matches the fixable:VALUE token. Mirrors the bash
// `grep -oE 'fixable:(yes|no|unknown)'`.
var fixableRE = regexp.MustCompile(`fixable:(yes|no|unknown)`)

// ParseReport scans path for the `## Findings` section and returns each
// `- [SEV] [fixable:V] desc` row as a Finding. Returns (nil, nil) when path
// does not exist — matches the bash semantics that a missing report means
// "no findings, proceed".
//
// Mirrors lib/security_helpers.sh::_parse_security_findings.
func ParseReport(path string) ([]Finding, error) {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var out []Finding
	in := false
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "## Findings") {
			in = true
			continue
		}
		if in && strings.HasPrefix(line, "## ") {
			break
		}
		if !in || !strings.HasPrefix(line, "- ") {
			continue
		}
		sevMatch := severityRE.FindStringSubmatch(line)
		if len(sevMatch) < 2 {
			// Row without a recognized severity — bash also skips it.
			continue
		}
		fix := "unknown"
		if m := fixableRE.FindStringSubmatch(line); len(m) >= 2 {
			fix = m[1]
		}
		// Description is everything after the first `] ` — matches bash
		// `${line#*] }`.
		desc := line
		if i := strings.Index(line, "] "); i >= 0 {
			desc = line[i+2:]
		}
		out = append(out, Finding{
			Severity:    Severity(sevMatch[1]),
			Fixable:     fix,
			Description: desc,
		})
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// docsExt is the allowlist that lets a file count as "not code" for the
// fast-path skip. Mirrors lib/security_helpers.sh:43-48 verbatim.
var docsExt = map[string]bool{
	"md": true, "txt": true, "rst": true, "csv": true,
	"json": true, "yaml": true, "yml": true, "toml": true, "cfg": true,
	"png": true, "jpg": true, "jpeg": true, "gif": true, "svg": true,
	"ico": true, "woff": true, "woff2": true, "ttf": true, "eot": true,
}

// IsDocsOnly reports whether every file extracted from the coder summary at
// summaryPath is in the docs/config/assets allowlist. Mirrors
// lib/security_helpers.sh::_security_is_docs_only including its return-code
// inversion: bash returns 0 (true) when the scan can be skipped.
//
//   - Summary missing                → (false, nil)   "scan anyway"
//   - Summary present but empty list → (true,  nil)   "nothing to scan"
//   - Any file outside the allowlist → (false, nil)   "code file present"
//   - All files in the allowlist     → (true,  nil)   "docs only — skip"
func IsDocsOnly(summaryPath string) (bool, error) {
	if _, err := os.Stat(summaryPath); os.IsNotExist(err) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	files, err := extractFilesFromCoderSummary(summaryPath)
	if err != nil {
		return false, err
	}
	if len(files) == 0 {
		return true, nil
	}
	for _, f := range files {
		ext := strings.TrimPrefix(filepath.Ext(f), ".")
		if !docsExt[ext] {
			return false, nil
		}
	}
	return true, nil
}

// extractFilesFromCoderSummary ports lib/indexer_helpers.sh's
// extract_files_from_coder_summary. It scans for the `## Files Modified` or
// `## Files Created` heading and returns the file path from each bullet row
// until the next `## ` heading, mirroring the bash awk + while-read loop.
func extractFilesFromCoderSummary(path string) ([]string, error) {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var out []string
	in := false
	sc := bufio.NewScanner(f)
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
		cleaned := cleanFileBullet(line)
		if cleaned == "" || cleaned == "None" || strings.HasPrefix(cleaned, "(fill") {
			continue
		}
		out = append(out, cleaned)
	}
	return out, sc.Err()
}

// cleanFileBullet mirrors the bash bullet-stripping chain:
//
//	cleaned="${line#*- }"        # strip leading "- "
//	cleaned="${cleaned#\`}"      # strip leading backtick
//	cleaned="${cleaned%%\`*}"    # truncate at next backtick
//	cleaned="${cleaned%% —*}"   # truncate at " — " separator
//	cleaned="${cleaned%% *}"     # truncate at first space
func cleanFileBullet(line string) string {
	if !strings.HasPrefix(line, "- ") && !strings.Contains(line, "- ") {
		return ""
	}
	cleaned := line
	if i := strings.Index(cleaned, "- "); i >= 0 {
		cleaned = cleaned[i+2:]
	}
	cleaned = strings.TrimPrefix(cleaned, "`")
	if i := strings.Index(cleaned, "`"); i >= 0 {
		cleaned = cleaned[:i]
	}
	if i := strings.Index(cleaned, " —"); i >= 0 {
		cleaned = cleaned[:i]
	}
	if i := strings.Index(cleaned, " "); i >= 0 {
		cleaned = cleaned[:i]
	}
	return strings.TrimSpace(cleaned)
}
