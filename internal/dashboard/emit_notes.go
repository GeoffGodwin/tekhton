// emit_notes.go — notes.js emit. Ports
// lib/dashboard_emitters.sh:emit_dashboard_notes — the M40/M41/M42 per-note
// structured data with metadata extraction.

package dashboard

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EmitNotes writes data/notes.js by parsing HUMAN_NOTES.md into a
// structured per-note array including triage / acceptance metadata.
func (e *Emitter) EmitNotes() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	notes := parseHumanNotesFile(e.HumanNotesFile)
	payload := proto.DashboardNotesV1{Notes: notes}
	return WriteJSFile(filepath.Join(e.DashDir, "data", "notes.js"),
		proto.DashboardVarNotes, payload, e.nowFn())
}

var (
	noteHeaderRE = regexp.MustCompile(`^- \[([x ~])\] `)
	noteIDRE     = regexp.MustCompile(`(?:^|\s)note:([^ >]+)`)
	notePairRE   = regexp.MustCompile(`(\w+):([^ >]+)`)
)

// parseHumanNotesFile is a streaming scan of HUMAN_NOTES.md. For each
// `- [ ]` / `- [~]` / `- [x]` line, it builds a DashboardNote from the
// header line plus any blockquote (`>`) description lines that follow.
func parseHumanNotesFile(path string) []proto.DashboardNote {
	out := []proto.DashboardNote{}
	if path == "" {
		return out
	}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer func() { _ = f.Close() }()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)

	var lines []string
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	for i := 0; i < len(lines); i++ {
		line := lines[i]
		m := noteHeaderRE.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		status := statusFromChar(m[1])
		tag := tagFromLine(line)
		title := extractNoteTitle(line, tag)
		desc := extractDescription(lines, i+1)

		meta := extractMetadata(line)
		acceptanceVal := meta["acceptance"]

		rcaPresent := false
		if status == "done" && tag == "BUG" {
			if acceptanceVal != "" && !strings.Contains(acceptanceVal, "warn_no_rca") {
				rcaPresent = true
			}
		}

		out = append(out, proto.DashboardNote{
			ID:                meta["note"],
			Tag:               tag,
			Title:             title,
			Description:       desc,
			Status:            status,
			Priority:          meta["priority"],
			Source:            meta["source"],
			Created:           meta["created"],
			TriageDisposition: meta["triage"],
			EstimatedTurns:    meta["est_turns"],
			TriagedAt:         meta["triaged"],
			Promoted:          meta["promoted"],
			AcceptanceResult:  acceptanceVal,
			CompletedAt:       meta["completed"],
			TurnsUsed:         meta["turns_used"],
			ReviewerSkipped:   meta["reviewer_skipped"],
			RCAPresent:        rcaPresent,
		})
	}
	return out
}

func statusFromChar(c string) string {
	switch c {
	case "x":
		return "done"
	case "~":
		return "claimed"
	default:
		return "open"
	}
}

func tagFromLine(line string) string {
	switch {
	case strings.Contains(line, "[BUG]"):
		return "BUG"
	case strings.Contains(line, "[FEAT]"):
		return "FEAT"
	case strings.Contains(line, "[POLISH]"):
		return "POLISH"
	}
	return ""
}

// extractNoteTitle strips the checkbox, optional tag, and metadata
// comment to leave the human-readable note title.
func extractNoteTitle(line, tag string) string {
	// strip checkbox
	s := line
	if loc := strings.Index(s, "] "); loc >= 0 {
		s = s[loc+2:]
	}
	if tag != "" {
		needle := "[" + tag + "] "
		s = strings.TrimPrefix(s, needle)
	}
	if cut := strings.Index(s, "<!-- note:"); cut >= 0 {
		s = strings.TrimRight(s[:cut], " \t")
	}
	return s
}

// extractDescription collects indented blockquote lines following a note
// header. Stops at the first non-blockquote line.
func extractDescription(lines []string, start int) string {
	var out []string
	for j := start; j < len(lines); j++ {
		s := lines[j]
		ltrim := strings.TrimLeft(s, " \t")
		if !strings.HasPrefix(ltrim, ">") {
			break
		}
		text := strings.TrimPrefix(ltrim, ">")
		text = strings.TrimPrefix(text, " ")
		out = append(out, text)
	}
	return strings.Join(out, " ")
}

// extractMetadata reads the `<!-- note:foo created:bar ... -->` trailer
// into a map. Treats keys without an explicit ID prefix as plain.
func extractMetadata(line string) map[string]string {
	out := map[string]string{}
	start := strings.Index(line, "<!--")
	if start < 0 {
		return out
	}
	body := line[start+4:]
	if end := strings.Index(body, "-->"); end >= 0 {
		body = body[:end]
	}
	// Special-case `note:<id>` since the id can contain dashes and
	// underscores; the generic key:value RE captures only the first run
	// of non-space.
	if m := noteIDRE.FindStringSubmatch(body); len(m) > 1 {
		out["note"] = m[1]
	}
	for _, kv := range notePairRE.FindAllStringSubmatch(body, -1) {
		if len(kv) < 3 {
			continue
		}
		key := kv[1]
		if key == "note" {
			continue
		}
		out[key] = kv[2]
	}
	return out
}
