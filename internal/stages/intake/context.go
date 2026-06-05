package intake

import (
	"bufio"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/notes"
	"github.com/geoffgodwin/tekhton/internal/prompt"
)

// buildPromptVars assembles the prompt-variable map the intake_scan template
// consumes. Each helper is best-effort: missing files / failed subprocesses
// yield empty strings — matching the bash semantics where each export was
// guarded by `2>/dev/null || true`.
func buildPromptVars(ctx context.Context, cfg config, content string) map[string]string {
	vars := prompt.EnvVars()
	vars["INTAKE_MILESTONE_CONTENT"] = content
	vars["INTAKE_PROJECT_INDEX"] = buildProjectIndex(ctx, cfg)
	vars["INTAKE_HISTORY_BLOCK"] = buildHistoryBlock(ctx, cfg)
	vars["HEALTH_SCORE_SUMMARY"] = buildHealthSummary(ctx, cfg)
	vars["INTAKE_ROLE_CONTENT"] = buildIntakeRoleContent(cfg)
	vars["NOTES_CONTEXT_BLOCK"] = buildNotesContext(ctx, cfg)
	vars["UI_PROJECT_DETECTED"] = cfg.UIProjectDetected
	vars["UI_FRAMEWORK"] = cfg.UIFramework
	vars["INTAKE_REPORT_FILE"] = cfg.ReportFile
	vars["TASK"] = cfg.Task
	return vars
}

// buildProjectIndex returns the bounded project-index summary (8KB cap).
// Mirrors bash lines 110-113 — calls `tekhton index summary` when either
// .claude/index/ or the legacy PROJECT_INDEX_FILE is present.
func buildProjectIndex(ctx context.Context, cfg config) string {
	indexDir := filepath.Join(cfg.ProjectDir, ".claude", "index")
	legacy := resolveProjectRelative(cfg.ProjectDir, cfg.ProjectIndexFile)
	if !fileExists(indexDir) && !fileExists(legacy) {
		return ""
	}
	bin := resolveTekhtonBin()
	if bin == "" {
		// Fall back to reading the legacy file directly (8KB cap).
		if fileExists(legacy) {
			data, err := os.ReadFile(legacy)
			if err == nil {
				return capBytes(string(data), 8000)
			}
		}
		return ""
	}
	cmd := exec.CommandContext(ctx, bin, "index", "summary", "--budget", "8000")
	if cfg.ProjectDir != "" {
		cmd.Dir = cfg.ProjectDir
	}
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return string(out)
}

// buildHistoryBlock returns the intake history block, preferring structured
// run-memory (M49) and falling back to causal-log verdict history (M86).
// Mirrors bash lines 116-130.
func buildHistoryBlock(ctx context.Context, cfg config) string {
	bin := resolveTekhtonBin()
	if bin == "" {
		return ""
	}
	// Try the structured run-memory path first.
	if out := tekhtonOutput(ctx, bin, cfg.ProjectDir,
		"causal", "intake-history-from-memory", "--task", cfg.Task); out != "" {
		return out
	}
	if !cfg.CausalLogEnabled {
		return ""
	}
	hist := tekhtonOutput(ctx, bin, cfg.ProjectDir,
		"causal", "verdict-history", "--stage", "intake", "--limit", "10")
	rework := tekhtonOutput(ctx, bin, cfg.ProjectDir,
		"causal", "events-by-type", "--type", "rework_cycle", "--limit", "10")
	if rework != "" {
		if hist != "" {
			hist += "\n"
		}
		hist += "Rework patterns: " + rework
	}
	return hist
}

// buildHealthSummary returns the project health summary block. Mirrors bash
// lines 132-136: skipped entirely when HEALTH_ENABLED is false.
func buildHealthSummary(ctx context.Context, cfg config) string {
	if !cfg.HealthEnabled {
		return ""
	}
	bin := resolveTekhtonBin()
	if bin == "" {
		return ""
	}
	return tekhtonOutput(ctx, bin, cfg.ProjectDir, "health", "summary")
}

// buildIntakeRoleContent returns the intake role-file body wrapped in the
// bash-style BEGIN/END FILE CONTENT delimiters. Mirrors bash lines 138-143
// + _wrap_file_content from lib/prompts_io.sh.
func buildIntakeRoleContent(cfg config) string {
	rolePath := resolveProjectRelative(cfg.ProjectDir, cfg.RoleFile)
	if !fileExists(rolePath) {
		return ""
	}
	data, err := os.ReadFile(rolePath)
	if err != nil {
		return ""
	}
	body := string(data)
	if len(body) > 1024*1024 {
		body = body[:1024*1024]
	}
	return body
}

// buildNotesContext returns the keyword-overlap-filtered subset of human
// notes for the active task. Mirrors bash lines 145-179: extract notes
// (in-process via internal/notes), then filter by 4-char-min word overlap
// with TASK.
func buildNotesContext(_ context.Context, cfg config) string {
	notesPath := resolveProjectRelative(cfg.ProjectDir, cfg.HumanNotesFile)
	if !fileExists(notesPath) {
		return ""
	}
	out, err := notes.ExtractFromProject(cfg.ProjectDir, notes.ExtractOpts{})
	if err != nil || out == "" {
		return ""
	}
	matching := matchNotes(cfg.Task, splitLines(out))
	if len(matching) == 0 {
		return ""
	}
	return strings.Join(matching, "\n") + "\n"
}

// matchNotes filters notes by 4-char-min word overlap with task. Lower-case
// substring match — mirrors bash lines 157-174.
func matchNotes(task string, allNotes []string) []string {
	taskWords := extractWords(task, 4)
	if len(taskWords) == 0 {
		return nil
	}
	var matching []string
	for _, note := range allNotes {
		if note == "" {
			continue
		}
		lower := strings.ToLower(note)
		for _, w := range taskWords {
			if strings.Contains(lower, w) {
				matching = append(matching, note)
				break
			}
		}
	}
	return matching
}

// wordRE matches runs of 4+ ASCII letters in a lowercased string. Mirrors
// bash `grep -oE '[a-z]{4,}'`.
var wordRE = regexp.MustCompile(`[a-z]{4,}`)

// extractWords returns the unique sorted set of 4+ char lowercase ASCII
// words from s. Mirrors bash `tr | grep -oE | sort -u`.
func extractWords(s string, _ int) []string {
	lower := strings.ToLower(s)
	hits := wordRE.FindAllString(lower, -1)
	seen := make(map[string]struct{}, len(hits))
	for _, w := range hits {
		seen[w] = struct{}{}
	}
	out := make([]string, 0, len(seen))
	for w := range seen {
		out = append(out, w)
	}
	sort.Strings(out)
	return out
}

// tekhtonOutput execs `<bin> <args...>` and returns stdout trimmed of
// trailing newlines. Returns "" on any failure (best-effort).
func tekhtonOutput(ctx context.Context, bin, dir string, args ...string) string {
	cmd := exec.CommandContext(ctx, bin, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(out), "\n")
}

func splitLines(s string) []string {
	if s == "" {
		return nil
	}
	var lines []string
	sc := bufio.NewScanner(strings.NewReader(s))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	return lines
}

func fileExists(p string) bool {
	if p == "" {
		return false
	}
	_, err := os.Stat(p)
	return err == nil
}

func capBytes(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
