// emit_inbox.go — inbox.js, action_items.js, notes.js, draft_milestones.js
// emit. Ports the inbox-family quartet from lib/dashboard_emitters.sh:407-684
// (emit_dashboard_inbox + emit_dashboard_action_items + emit_dashboard_notes
// + emit_draft_milestones_data).

package dashboard

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EmitInbox writes data/inbox.js by scanning .claude/watchtower_inbox/
// for note_*.md, milestone_*.md, and task_*.txt files. Each entry carries
// the parsed title plus the submitted timestamp.
func (e *Emitter) EmitInbox() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	inboxDir := filepath.Join(e.ProjectDir, ".claude", "watchtower_inbox")
	items := scanInboxItems(inboxDir)
	payload := proto.DashboardInboxV1{Items: items}
	return WriteJSFile(filepath.Join(e.DashDir, "data", "inbox.js"),
		proto.DashboardVarInbox, &payload, e.nowFn())
}

func scanInboxItems(inboxDir string) []proto.DashboardInboxItem {
	out := []proto.DashboardInboxItem{}
	entries, err := os.ReadDir(inboxDir)
	if err != nil {
		return out
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		path := filepath.Join(inboxDir, name)
		item := parseInboxItem(name, path)
		if item.Filename == "" {
			continue
		}
		out = append(out, item)
	}
	return out
}

var titleStripper = regexp.MustCompile(`^- \[ \] \[[A-Z]+\] `)

func parseInboxItem(basename, path string) proto.DashboardInboxItem {
	var ftype, title string
	switch {
	case strings.HasPrefix(basename, "note_"):
		ftype = "note"
		title = firstMatching(path, func(line string) (string, bool) {
			if strings.HasPrefix(line, "- [ ] [") {
				return titleStripper.ReplaceAllString(line, ""), true
			}
			return "", false
		})
	case strings.HasPrefix(basename, "milestone_"):
		ftype = "milestone"
		title = firstMatching(path, func(line string) (string, bool) {
			if strings.HasPrefix(line, "# Milestone") {
				return strings.TrimPrefix(line, "# "), true
			}
			return "", false
		})
	case strings.HasPrefix(basename, "task_"):
		ftype = "task"
		title = firstLine(path)
	default:
		return proto.DashboardInboxItem{}
	}

	submitted := firstMatching(path, func(line string) (string, bool) {
		if strings.HasPrefix(line, "Submitted: ") {
			return strings.TrimPrefix(line, "Submitted: "), true
		}
		return "", false
	})
	if submitted == "" {
		if fi, err := os.Stat(path); err == nil {
			submitted = fi.ModTime().UTC().Format("2006-01-02T15:04:05Z")
		}
	}
	if len(title) > 80 {
		title = title[:79] + "..."
	}
	return proto.DashboardInboxItem{
		Type:      ftype,
		Title:     title,
		Filename:  basename,
		Submitted: submitted,
	}
}

func firstMatching(path string, fn func(string) (string, bool)) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer func() { _ = f.Close() }()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		if out, ok := fn(scanner.Text()); ok {
			return out
		}
	}
	return ""
}

func firstLine(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer func() { _ = f.Close() }()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	if scanner.Scan() {
		return scanner.Text()
	}
	return ""
}

// EmitActionItems writes data/action_items.js with severity-annotated
// counts. m33.1 reads counts from env vars set by the bash hook before
// the exec (matching the bash form, which sources notes/drift modules
// in-process); when those env vars are absent everything zeros out.
func (e *Emitter) EmitActionItems() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	nbCount := envInt("_NONBLOCKING_COUNT", 0)
	hnCount := envInt("_HUMAN_NOTES_UNCHECKED", 0)
	driftCount := envInt("_DRIFT_COUNT", 0)
	haCount := envInt("_HUMAN_ACTION_COUNT", 0)

	payload := proto.DashboardActionItemsV1{
		Nonblocking: proto.DashboardSeverityCount{
			Count:    nbCount,
			Severity: severityForCount(nbCount, envInt("ACTION_ITEMS_WARN_THRESHOLD", 5), envInt("ACTION_ITEMS_CRITICAL_THRESHOLD", 10)),
		},
		HumanNotes: proto.DashboardSeverityCount{
			Count:    hnCount,
			Severity: severityForCount(hnCount, envInt("HUMAN_NOTES_WARN_THRESHOLD", 10), envInt("HUMAN_NOTES_CRITICAL_THRESHOLD", 20)),
		},
		Drift:        proto.DashboardCount{Count: driftCount},
		HumanActions: proto.DashboardCount{Count: haCount},
	}
	return WriteJSFile(filepath.Join(e.DashDir, "data", "action_items.js"),
		proto.DashboardVarActionItems, &payload, e.nowFn())
}

func severityForCount(count, warn, crit int) string {
	switch {
	case count >= crit:
		return "critical"
	case count >= warn:
		return "warning"
	default:
		return "normal"
	}
}

// EmitDraftMilestones writes data/draft_milestones.js — currently always
// an empty array (full Watchtower UI integration is a future V4 milestone).
func (e *Emitter) EmitDraftMilestones() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	return WriteJSFile(filepath.Join(e.DashDir, "data", "draft_milestones.js"),
		proto.DashboardVarDraftMilestones, proto.DashboardDraftMilestonesV1{}, e.nowFn())
}
