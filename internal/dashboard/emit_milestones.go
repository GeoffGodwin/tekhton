// emit_milestones.go — milestones.js emit. Ports
// lib/dashboard_emitters.sh:emit_dashboard_milestones +
// _extract_milestone_summary.

package dashboard

import (
	"bufio"
	"fmt"
	stdio "io"
	"os"
	"path/filepath"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EmitMilestones reads MANIFEST.cfg, enriches each row with summary
// (extracted from the milestone .md file's ## Overview block) and enables
// (reverse-dependency map), and writes data/milestones.js.
func (e *Emitter) EmitMilestones() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	manifest, err := os.Open(e.ManifestPath)
	if err != nil {
		if os.IsNotExist(err) {
			// No manifest — emit an empty array (matches bash falling
			// through with no rows).
			return WriteJSFile(filepath.Join(e.DashDir, "data", "milestones.js"),
				proto.DashboardVarMilestones, proto.DashboardMilestonesV1{}, e.nowFn())
		}
		return fmt.Errorf("EmitMilestones: open manifest: %w", err)
	}
	defer func() { _ = manifest.Close() }()

	rows := parseManifest(manifest)
	enables := buildEnablesMap(rows)
	entries := make([]proto.DashboardMilestoneEntry, 0, len(rows))
	for _, r := range rows {
		summary := ""
		if r.file != "" {
			summary = e.extractMilestoneSummary(filepath.Join(e.MilestoneDir, r.file))
		}
		entries = append(entries, proto.DashboardMilestoneEntry{
			ID:            r.id,
			Title:         r.title,
			Status:        r.status,
			DependsOn:     r.deps,
			ParallelGroup: r.pgroup,
			Summary:       summary,
			Enables:       enables[r.id],
		})
	}
	payload := proto.DashboardMilestonesV1{Entries: entries}
	return WriteJSFile(filepath.Join(e.DashDir, "data", "milestones.js"),
		proto.DashboardVarMilestones, payload, e.nowFn())
}

// manifestRow is one parsed line of MANIFEST.cfg. Fields mirror the
// pipe-delimited row format.
type manifestRow struct {
	id, title, status, deps, file, pgroup string
}

// parseManifest reads all non-comment rows of MANIFEST.cfg. Comments
// (`# ...`) and blank lines are skipped; whitespace around each field is
// trimmed.
func parseManifest(r stdio.Reader) []manifestRow {
	var out []manifestRow
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Split(line, "|")
		for i := range fields {
			fields[i] = strings.TrimSpace(fields[i])
		}
		row := manifestRow{}
		switch len(fields) {
		case 6:
			row.pgroup = fields[5]
			fallthrough
		case 5:
			row.file = fields[4]
			fallthrough
		case 4:
			row.deps = fields[3]
			fallthrough
		case 3:
			row.status = fields[2]
			fallthrough
		case 2:
			row.title = fields[1]
			fallthrough
		case 1:
			row.id = fields[0]
		}
		if row.id == "" {
			continue
		}
		out = append(out, row)
	}
	return out
}

// buildEnablesMap inverts the depends_on graph: for each milestone id,
// return the comma-separated list of milestones that depend on it.
func buildEnablesMap(rows []manifestRow) map[string]string {
	out := make(map[string]string, len(rows))
	for _, r := range rows {
		if r.deps == "" {
			continue
		}
		for _, dep := range strings.Split(r.deps, ",") {
			dep = strings.TrimSpace(dep)
			if dep == "" {
				continue
			}
			if existing := out[dep]; existing != "" {
				out[dep] = existing + "," + r.id
			} else {
				out[dep] = r.id
			}
		}
	}
	return out
}

// extractMilestoneSummary reads the first paragraph of `## Overview` from
// a milestone .md file. Capped at 300 characters. Returns "" if no
// Overview header is found.
func (e *Emitter) extractMilestoneSummary(path string) string {
	if path == "" {
		return ""
	}
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer func() { _ = f.Close() }()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	var summary strings.Builder
	inOverview := false
	for scanner.Scan() {
		line := scanner.Text()
		if !inOverview {
			if strings.HasPrefix(strings.TrimLeft(line, " \t"), "## Overview") ||
				strings.HasPrefix(strings.TrimLeft(line, " \t"), "##  Overview") {
				inOverview = true
			}
			continue
		}
		// Stop at next H2 heading.
		if strings.HasPrefix(strings.TrimLeft(line, " \t"), "## ") &&
			!strings.HasPrefix(strings.TrimLeft(line, " \t"), "## Overview") {
			break
		}
		trimmed := strings.TrimSpace(line)
		// Skip blank lines before first content; stop at blank line after.
		if trimmed == "" {
			if summary.Len() == 0 {
				continue
			}
			break
		}
		if summary.Len() > 0 {
			summary.WriteString(" ")
		}
		summary.WriteString(line)
	}
	out := summary.String()
	if len(out) > 300 {
		out = out[:297] + "..."
	}
	return out
}
