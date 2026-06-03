package cleanup

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/notes"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// Result records the mutation counts a single cleanup sweep produced.
// Returned by processResults so the stage entry can format the final
// success message in the same shape as the bash log line.
type Result struct {
	Resolved int
	Deferred int
}

// processResults routes between the structured-report path (when the
// agent wrote CLEANUP_REPORT.md) and the file-change-heuristic fallback.
// Ports stages/cleanup.sh::_process_cleanup_results.
//
// On build-gate failure (buildPass=false) no items are marked — matches
// the bash early-return at line 162. The doc parameter must be the
// already-loaded NON_BLOCKING_LOG document; mutations land on it
// in-place so the caller can Save() once at the end.
func processResults(doc *notes.Document, batch []*notes.Note, buildPass bool, req *proto.StageRequestV1) Result {
	res := Result{}
	if !buildPass {
		return res
	}
	reportPath := cleanupReportPath(req)
	if reportPath != "" && fileExists(reportPath) {
		res = parseReport(doc, batch, reportPath)
		archiveReport(reportPath, req)
		return res
	}
	return resolveByFileChanges(doc, batch)
}

// parseReport reads CLEANUP_REPORT.md, extracts the `## Resolved` and
// `## Deferred` sections, and calls notes.MarkResolved / notes.MarkDeferred
// for each line whose text matches one of the originally-selected batch
// items.
//
// The `## Not Attempted` section is deliberately NOT parsed — items the
// agent did not attempt stay `[ ]` so they reappear in future sweeps.
// Matches the bash comment at stages/cleanup.sh:191-194.
func parseReport(doc *notes.Document, batch []*notes.Note, reportPath string) Result {
	res := Result{}
	raw, err := os.ReadFile(reportPath)
	if err != nil {
		return res
	}
	content := string(raw)

	for _, line := range extractMarkdownSection(content, "## Resolved") {
		text := stripBulletPrefix(line, "[x] ")
		if !matchesBatch(text, batch) {
			continue
		}
		if notes.MarkResolved(doc, text) {
			res.Resolved++
		}
	}
	for _, line := range extractMarkdownSection(content, "## Deferred") {
		text := stripBulletPrefix(line, "[DEFERRED] ")
		// The bash version split on `:` and kept the LHS — the report
		// format is `- [DEFERRED] <text>: <reason>`. Replicate.
		if idx := strings.Index(text, ":"); idx >= 0 {
			text = text[:idx]
		}
		text = strings.TrimSpace(text)
		if !matchesBatch(text, batch) {
			continue
		}
		if notes.MarkDeferred(doc, text) {
			res.Deferred++
		}
	}
	return res
}

// resolveByFileChanges is the fallback heuristic — when no
// CLEANUP_REPORT.md exists, treat any batch note whose body mentions a
// basename from `git diff --name-only` as resolved. Ports
// stages/cleanup.sh::_resolve_cleanup_by_file_changes.
func resolveByFileChanges(doc *notes.Document, batch []*notes.Note) Result {
	res := Result{}
	modified, _ := gitDiffNameOnly()
	if len(modified) == 0 {
		return res
	}
	for _, n := range batch {
		for _, f := range modified {
			base := filepath.Base(f)
			if base == "" {
				continue
			}
			if strings.Contains(n.Title, base) {
				if notes.MarkResolved(doc, n.Title) {
					res.Resolved++
				}
				break
			}
		}
	}
	return res
}

// matchesBatch reports whether text overlaps with any selected batch
// note. The bash version's `grep -qF` was substring-match against the
// raw note line; the Go version checks Title for symmetry with how the
// agent reports it. Returns true when text is empty for parity with the
// bash check (an empty extracted line passed the grep too — and bash
// skipped that branch via the `[ -z "$resolved_line" ] && continue`
// guard inside the loop).
func matchesBatch(text string, batch []*notes.Note) bool {
	if text == "" {
		return false
	}
	for _, n := range batch {
		if n == nil {
			continue
		}
		if strings.Contains(n.Title, text) || strings.Contains(text, n.Title) {
			return true
		}
	}
	return false
}

// stripBulletPrefix removes the leading `- ` and optionally the supplied
// state marker. Mirrors the bash sed strip pattern `s/^- (\[x\] )?//`.
func stripBulletPrefix(line, optionalMarker string) string {
	line = strings.TrimPrefix(line, "- ")
	line = strings.TrimPrefix(line, optionalMarker)
	return strings.TrimSpace(line)
}

// extractMarkdownSection returns every `- ` bullet line that appears
// between sectionHeader and the next `##` heading. Ports the awk
// `/^## Resolved/{found=1; next} found && /^##/{exit} found && /^- /{print}`
// pattern from stages/cleanup.sh:201-207.
func extractMarkdownSection(content, sectionHeader string) []string {
	var out []string
	inSection := false
	for _, line := range strings.Split(content, "\n") {
		if strings.HasPrefix(line, sectionHeader) {
			inSection = true
			continue
		}
		if inSection && strings.HasPrefix(line, "##") {
			break
		}
		if inSection && strings.HasPrefix(line, "- ") {
			out = append(out, line)
		}
	}
	return out
}
