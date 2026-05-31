// Engine — the m32.1 orchestrator port of lib/diagnose.sh::run_diagnose.
//
// Engine.ReadContext aggregates the four input state files
// (PIPELINE_STATE.md, RUN_SUMMARY.json, LAST_FAILURE_CONTEXT.json,
// CAUSAL_LOG.jsonl) into a *Context. Engine.Run walks the RuleProvider's
// priority-ordered rules top-down and stops at the first Match, emitting
// the bash-parity `[diag] rule=...` one-liner to the configured Logger.
//
// m32.1 ships with a BashRuleAdapter as the default RuleProvider so the
// observable verdict stays identical to v4.31.x; m32.2 will replace the
// adapter with a Go-native registry.

package diagnose

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/state"
)

// Input is the value passed to Engine.ReadContext. It carries the two
// directory roots and lets tests inject a per-call PROJECT_DIR without
// mutating the process environment.
type Input struct {
	ProjectDir  string
	TekhtonHome string
}

// Engine is the m32.1 orchestrator. The fields are public so callers can
// swap a fake Provider, a quiet Logger, or an explicit Helpers in tests.
type Engine struct {
	Provider RuleProvider
	Helpers  *Helpers
	Logger   io.Writer
}

// NewEngine constructs an Engine with the supplied Provider, default
// Helpers, and a no-op logger (callers can override Logger before Run).
func NewEngine(p RuleProvider) *Engine {
	return &Engine{
		Provider: p,
		Helpers:  DefaultHelpers(),
		Logger:   io.Discard,
	}
}

// Run walks the priority-ordered rule registry and returns the first
// matching Diagnosis. Mirrors lib/diagnose.sh::classify_failure_diag —
// a "success" outcome short-circuits before any rule runs; the final
// _rule_unknown is expected to always match so the fallback below is
// defensive (a misconfigured Provider with no unknown rule still produces
// a sane verdict).
func (e *Engine) Run(_ context.Context, in *Context) Diagnosis {
	if in == nil {
		return Diagnosis{
			Classification: "UNKNOWN",
			Confidence:     ConfidenceLow,
			Suggestions:    []string{"No diagnostic context available."},
		}
	}

	if in.Outcome == "success" {
		return Diagnosis{
			Classification: "SUCCESS",
			Confidence:     ConfidenceHigh,
			Suggestions:    []string{"Last run completed successfully. No issues found."},
		}
	}

	rules := []Rule{}
	if e.Provider != nil {
		rules = e.Provider.Rules()
	}
	for _, r := range rules {
		d, ok := r.Match(in)
		if !ok {
			continue
		}
		if d.RuleName == "" {
			d.RuleName = r.Name()
		}
		if e.Helpers != nil {
			d.Recurring = e.Helpers.DetectRecurring(in, d.Classification)
		}
		e.emitRuleMatch(d)
		return d
	}
	return Diagnosis{
		Classification: "UNKNOWN",
		Confidence:     ConfidenceLow,
		Suggestions:    []string{"No specific failure pattern identified."},
	}
}

// emitRuleMatch writes the byte-identical
// `[diag] rule=NAME confidence=LEVEL classification=CLASS stage=STAGE`
// line the bash parity gate asserts on. Goes to Logger (typically stderr).
func (e *Engine) emitRuleMatch(d Diagnosis) {
	if e.Logger == nil {
		return
	}
	fmt.Fprintf(e.Logger, "[diag] rule=%s confidence=%s classification=%s stage=%s\n",
		d.RuleName, string(d.Confidence), d.Classification, d.Stage)
}

// ReadContext is the m32.1 port of _read_diagnostic_context. Returns
// (nil, nil) when no pipeline run is present (state file, RUN_SUMMARY,
// causal log, LAST_FAILURE_CONTEXT, and migration backups are ALL absent).
// Otherwise returns a populated *Context suitable for Engine.Run.
func (e *Engine) ReadContext(_ context.Context, in *Input) (*Context, error) {
	if in == nil {
		in = &Input{}
	}
	projectDir := projectOrDot(in.ProjectDir)

	stateFile := os.Getenv("PIPELINE_STATE_FILE")
	if stateFile == "" {
		stateFile = filepath.Join(projectDir, ".claude", "PIPELINE_STATE.md")
	}
	causalLog := os.Getenv("CAUSAL_LOG_FILE")
	if causalLog == "" {
		causalLog = filepath.Join(projectDir, ".claude", "logs", "CAUSAL_LOG.jsonl")
	}
	summaryFile := filepath.Join(projectDir, ".claude", "logs", "RUN_SUMMARY.json")
	failureCtxFile := filepath.Join(projectDir, ".claude", "LAST_FAILURE_CONTEXT.json")
	backupDir := os.Getenv("MIGRATION_BACKUP_DIR")
	if backupDir == "" {
		backupDir = ".claude/migration-backups"
	}
	backupBase := filepath.Join(projectDir, backupDir)

	hasState := fileExists(stateFile) || fileExists(summaryFile) ||
		fileExists(causalLog) || fileExists(failureCtxFile)
	var backups []string
	if !hasState {
		backups = globPreBackups(backupBase)
		if len(backups) > 0 {
			hasState = true
		}
	} else {
		backups = globPreBackups(backupBase)
	}
	if !hasState {
		return nil, nil
	}

	c := &Context{
		ProjectDir:       projectDir,
		TekhtonHome:      in.TekhtonHome,
		MigrationBackups: backups,
	}
	c.BuildErrorsFile = resolveArtifactPath(projectDir, "BUILD_ERRORS_FILE", ".tekhton/BUILD_ERRORS.md")
	c.BuildRawErrorsFile = resolveArtifactPath(projectDir, "BUILD_RAW_ERRORS_FILE", ".tekhton/BUILD_RAW_ERRORS.txt")
	c.BuildFixReportFile = resolveArtifactPath(projectDir, "BUILD_FIX_REPORT_FILE", ".tekhton/BUILD_FIX_REPORT.md")

	// --- Pipeline state ---
	if fileExists(stateFile) {
		s := state.New(stateFile)
		if snap, err := s.Read(); err == nil && snap != nil {
			c.Stage = snap.ExitStage
			c.Task = snap.ResumeTask
			c.ExitReason = snap.ExitReason
		}
	}

	// --- LAST_FAILURE_CONTEXT.json (primary) ---
	if body, err := os.ReadFile(failureCtxFile); err == nil {
		text := string(body)
		c.Classification = extractJSONString(text, "classification")
		c.Outcome = extractJSONString(text, "outcome")
		if c.Stage == "" {
			c.Stage = extractJSONString(text, "stage")
		}
		if sv := extractJSONInt(text, "schema_version"); sv >= 0 {
			c.SchemaVersion = sv
		}
		parseCauseBlock(text, "primary_cause",
			&c.PrimaryCategory, &c.PrimarySubcategory,
			&c.PrimarySignal, &c.PrimarySource)
		parseCauseBlock(text, "secondary_cause",
			&c.SecondaryCategory, &c.SecondarySubcategory,
			&c.SecondarySignal, &c.SecondarySource)
	}

	// --- RUN_SUMMARY.json (enrichment) ---
	if body, err := os.ReadFile(summaryFile); err == nil {
		text := string(body)
		if c.Outcome == "" {
			c.Outcome = extractJSONString(text, "outcome")
		}
		c.Milestone = extractJSONString(text, "milestone")
		if rc := extractJSONInt(text, "rework_cycles"); rc > 0 {
			c.ReviewCycles = rc
		}
	}

	// --- Causal log ---
	if body, err := os.ReadFile(causalLog); err == nil && len(body) > 0 {
		c.CausalEvents = string(body)
		c.TerminalEvent = lastNonEmptyLine(c.CausalEvents)
		c.ErrorEvents = grepLines(c.CausalEvents, `"type":"error"`)
		if rv := countLinesMatchingBoth(c.CausalEvents, `"type":"verdict"`, `"stage":"reviewer"`); rv > c.ReviewCycles {
			c.ReviewCycles = rv
		}
		c.CauseChain = ""
		if e.Helpers != nil {
			c.CauseChainShort = e.Helpers.CollapseCauseChain(c.CauseChain)
		}
	}

	// --- Agent log tails ---
	if e.Helpers != nil {
		c.AgentLogTails = e.Helpers.CollectAgentLogTails(c)
	}

	return c, nil
}

// --- JSON field readers (line-based grep -oP equivalents) ------------------

var (
	doubleQuotedRe = regexp.MustCompile(`[a-z_]+`)
)

// extractJSONString returns the value of the first `"key":"<value>"` pair
// found in text. Mirrors the bash `grep -oP '"<key>"\s*:\s*"\K[^"]+'` reads
// in _read_diagnostic_context — sufficient for the flat, pretty-printed
// schema the bash writer emits, no JSON parsing required.
func extractJSONString(text, key string) string {
	pat := fmt.Sprintf(`"%s"\s*:\s*"([^"]*)"`, regexp.QuoteMeta(key))
	re, err := regexp.Compile(pat)
	if err != nil {
		return ""
	}
	m := re.FindStringSubmatch(text)
	if len(m) < 2 {
		return ""
	}
	return m[1]
}

// extractJSONInt returns the integer value of the first `"key":N` pair
// found in text. Returns -1 when absent.
func extractJSONInt(text, key string) int {
	pat := fmt.Sprintf(`"%s"\s*:\s*(\d+)`, regexp.QuoteMeta(key))
	re, err := regexp.Compile(pat)
	if err != nil {
		return -1
	}
	m := re.FindStringSubmatch(text)
	if len(m) < 2 {
		return -1
	}
	n, err := strconv.Atoi(m[1])
	if err != nil {
		return -1
	}
	return n
}

// parseCauseBlock ports lib/diagnose_helpers.sh::_diag_parse_cause_block.
// Line-based scan of the multi-line nested cause object — depends on the
// pretty-print contract (one key per line) that lib/diagnose_output.sh's
// writer guarantees. Avoids json.Unmarshal so a malformed sibling field
// does not zero the whole block.
func parseCauseBlock(text, blockKey string, outCat, outSub, outSig, outSrc *string) {
	open := fmt.Sprintf(`"%s"`, blockKey)
	idx := strings.Index(text, open)
	if idx < 0 {
		return
	}
	tail := text[idx:]
	braceIdx := strings.Index(tail, "{")
	if braceIdx < 0 {
		return
	}
	closeIdx := strings.Index(tail[braceIdx:], "}")
	if closeIdx < 0 {
		return
	}
	block := tail[braceIdx : braceIdx+closeIdx]
	scan := strings.Split(block, "\n")
	for _, line := range scan {
		k, v, ok := extractKVLine(line)
		if !ok {
			continue
		}
		switch k {
		case "category":
			*outCat = v
		case "subcategory":
			*outSub = v
		case "signal":
			*outSig = v
		case "source":
			*outSrc = v
		}
	}
}

// extractKVLine returns the first ("key", "value") pair on a line, mirroring
// the bash double-grep in _diag_parse_cause_block.
func extractKVLine(line string) (string, string, bool) {
	keyRe := regexp.MustCompile(`"([a-z_]+)"\s*:`)
	valRe := regexp.MustCompile(`"[a-z_]+"\s*:\s*"([^"]*)"`)
	km := keyRe.FindStringSubmatch(line)
	if len(km) < 2 {
		return "", "", false
	}
	vm := valRe.FindStringSubmatch(line)
	if len(vm) < 2 {
		return km[1], "", true
	}
	return km[1], vm[1], true
}

// --- Filesystem + line helpers ---------------------------------------------

func fileExists(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return !info.IsDir()
}

func resolveArtifactPath(projectDir, envKey, fallback string) string {
	rel := os.Getenv(envKey)
	if rel == "" {
		rel = fallback
	}
	if filepath.IsAbs(rel) {
		return rel
	}
	return filepath.Join(projectDir, rel)
}

func globPreBackups(base string) []string {
	matches, err := filepath.Glob(filepath.Join(base, "pre-*"))
	if err != nil {
		return nil
	}
	return matches
}

func lastNonEmptyLine(body string) string {
	lines := strings.Split(strings.TrimRight(body, "\n"), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if strings.TrimSpace(lines[i]) != "" {
			return lines[i]
		}
	}
	return ""
}

func grepLines(body, needle string) string {
	var out []string
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, needle) {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}

func countLinesMatchingBoth(body, a, b string) int {
	count := 0
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, a) && strings.Contains(line, b) {
			count++
		}
	}
	return count
}

// --- Marshal helper for tests ----------------------------------------------

// jsonString is used by tests that want to introspect a Context. It is not
// part of the public engine API.
func (c *Context) jsonString() (string, error) {
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return "", err
	}
	return string(b), nil
}
