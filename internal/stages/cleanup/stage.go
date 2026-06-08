package cleanup

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/notes"
	"github.com/geoffgodwin/tekhton/internal/prompt"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/stages/staglog"
)

// BuildGateRunner is the seam for the post-cleanup build gate. The bash
// stage shelled to `run_build_gate`, which after m31.1 execs
// `tekhton gate build`. The Go port preserves the subprocess semantics
// behind an interface so tests can drive both pass and fail paths
// deterministically without invoking the real binary.
type BuildGateRunner interface {
	Run(ctx context.Context, projectDir, stageLabel string) error
}

// stageProvider is the package-level provider seam. Production code sets it
// via SetProvider before running the pipeline; tests inject a fake.
var stageProvider provider.Provider

// buildGateRunner is the package-level build-gate seam. Defaults to the
// subprocess implementation that execs `tekhton gate build`.
var buildGateRunner BuildGateRunner = subprocessBuildGate{}

// SetProvider replaces the package-level provider. Returns the previous value
// so callers can defer-restore.
func SetProvider(p provider.Provider) provider.Provider {
	prev := stageProvider
	stageProvider = p
	return prev
}

// RunStage is the m34.2 entry point. Signature matches
// stagerunner.StageImpl so DefaultStageDefs[StageCleanup] can register
// it directly. The cleanup stage never returns verdict=fail.
func RunStage(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	cfg := loadConfig()
	log := staglog.New(req)
	log.Header("Cleanup")

	projectDir := resolveProjectDir(req)
	nbPath := nonBlockingLogPath(projectDir, req)

	doc, err := loadNonBlockingDoc(nbPath)
	if err != nil {
		log.Warn(fmt.Sprintf("[cleanup] load %s: %v", nbPath, err))
		return skipResult(req, "notes-load-failed"), nil
	}

	if !shouldRun(doc) {
		log.Info("Trigger conditions not met. Skipping.")
		return skipResult(req, "no-trigger"), nil
	}

	unresolved := notes.UnresolvedCount(doc)
	threshold := envInt("CLEANUP_TRIGGER_THRESHOLD", 5)
	batchSize := envInt("CLEANUP_BATCH_SIZE", 5)
	log.Info(fmt.Sprintf("Unresolved non-blocking notes: %d (threshold: %d)", unresolved, threshold))
	log.Info(fmt.Sprintf("Selecting up to %d items for cleanup...", batchSize))

	modified := readModifiedFilesFromCoderSummary(projectDir)
	batch := notes.SelectCleanupBatch(doc, batchSize, modified)
	if len(batch) == 0 {
		log.Warn("No eligible notes for cleanup sweep.")
		return skipResult(req, "no-eligible-notes"), nil
	}
	log.Info(fmt.Sprintf("Selected %d item(s) for cleanup sweep.", len(batch)))

	promptText, err := renderCleanupPrompt(req, batch)
	if err != nil {
		log.Warn(fmt.Sprintf("[cleanup] render prompt: %v", err))
		return skipResult(req, "prompt-failed"), nil
	}

	// Snapshot pre-cleanup git state for selective revert on build-gate
	// failure. Bash captures this BEFORE invoking the agent (lines
	// 86-88) so primary-pipeline changes are protected.
	preCleanupFiles, _ := gitDiffNameOnly()

	turns := envInt("CLEANUP_MAX_TURNS", 15)
	log.Info(fmt.Sprintf("Invoking cleanup agent (jr coder, max %d turns)...", turns))

	agentRes, agentErr := invokeAgent(ctx, cfg, req, promptText, projectDir)
	if agentErr != nil {
		log.Warn(fmt.Sprintf("[cleanup] agent invocation failed: %v", agentErr))
	}
	log.Info("Cleanup agent finished.")

	// Null-run detection.
	if isNullRun(agentRes) {
		log.Warn("Cleanup agent was a null run — no debt items addressed.")
		return skipResult(req, "null-run"), nil
	}

	// Build gate (failure = warning + revert, not stage failure).
	buildPass := true
	if err := runBuildGate(ctx, projectDir, "post-cleanup"); err != nil {
		log.Warn("Build gate FAILED after cleanup sweep — reverting cleanup changes.")
		buildErrors := envOr("BUILD_ERRORS_FILE", ".tekhton/BUILD_ERRORS.md")
		log.Warn(fmt.Sprintf("Cleanup changes may have introduced issues. Review %s.", buildErrors))
		buildPass = false
		revertCleanupOnlyFiles(projectDir, preCleanupFiles)
	}

	res := processResults(doc, batch, buildPass, req)

	// Persist the mutated notes document. Failure to save is logged
	// but does not flip the stage to fail (matches bash: every branch
	// ends with success).
	if (res.Resolved > 0 || res.Deferred > 0) && doc != nil {
		if err := doc.Save(); err != nil {
			log.Warn(fmt.Sprintf("[cleanup] save %s: %v", nbPath, err))
		}
	}

	if res.Resolved > 0 || res.Deferred > 0 {
		log.Success(fmt.Sprintf("Cleanup sweep: %d resolved, %d deferred.", res.Resolved, res.Deferred))
	} else {
		log.Info("Cleanup sweep: no items conclusively resolved or deferred.")
	}

	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictPass,
		ExitReason: fmt.Sprintf("resolved=%d deferred=%d", res.Resolved, res.Deferred),
		AgentCalls: 1,
	}, nil
}

// SetBuildGateRunner replaces the package-level build-gate seam. Tests
// use this to drive the pass/fail/revert branches without invoking the
// real `tekhton gate build` subprocess.
func SetBuildGateRunner(r BuildGateRunner) BuildGateRunner {
	prev := buildGateRunner
	buildGateRunner = r
	return prev
}

func invokeAgent(ctx context.Context, cfg config, req *proto.StageRequestV1, promptText, projectDir string) (*provider.Result, error) {
	model := envOr("CLAUDE_JR_CODER_MODEL", "claude-sonnet-4-6")
	turns := envInt("CLEANUP_MAX_TURNS", 15)
	tools := envOr("AGENT_TOOLS_CLEANUP", envOr("AGENT_TOOLS_JR_CODER", "Read Write Edit Glob Grep Bash"))
	return cfg.Provider.RunAgent(ctx, &provider.Request{
		Prompt:       promptText,
		Label:        "Cleanup",
		Model:        model,
		MaxTurns:     turns,
		WorkingDir:   projectDir,
		AllowedTools: tools,
	})
}

func runBuildGate(ctx context.Context, projectDir, label string) error {
	return buildGateRunner.Run(ctx, projectDir, label)
}

func isNullRun(res *provider.Result) bool {
	return res == nil || res.NullRun
}

// subprocessBuildGate is the default BuildGateRunner — execs
// `tekhton gate build --stage-label <label>` in the project directory,
// matching the post-m31.1 bash compatibility shim that bash cleanup.sh
// transitively called.
type subprocessBuildGate struct{}

func (subprocessBuildGate) Run(ctx context.Context, projectDir, stageLabel string) error {
	bin := resolveTekhtonBin()
	if bin == "" {
		// Match the bash shim: missing binary → warn + skip (return
		// nil for "pass"), not a hard failure.
		return nil
	}
	cmd := exec.CommandContext(ctx, bin, "gate", "build", "--stage-label", stageLabel)
	if projectDir != "" {
		cmd.Dir = projectDir
	}
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func resolveTekhtonBin() string {
	if v := os.Getenv("TEKHTON_BIN"); v != "" {
		if _, err := os.Stat(v); err == nil {
			return v
		}
	}
	if home := os.Getenv("TEKHTON_HOME"); home != "" {
		cand := filepath.Join(home, "bin", "tekhton")
		if _, err := os.Stat(cand); err == nil {
			return cand
		}
	}
	if p, err := exec.LookPath("tekhton"); err == nil {
		return p
	}
	return ""
}

// loadNonBlockingDoc loads the NON_BLOCKING_LOG.md document. Returns a
// fresh empty document when the file does not exist — the cleanup
// trigger gates on UnresolvedCount which is 0 for empty docs.
func loadNonBlockingDoc(path string) (*notes.Document, error) {
	d, err := notes.Load(path)
	if err != nil {
		if errors.Is(err, notes.ErrNotFound) {
			d = &notes.Document{Path: path, Registry: notes.NewTagRegistry()}
			return d, nil
		}
		return nil, err
	}
	return d, nil
}

func nonBlockingLogPath(projectDir string, req *proto.StageRequestV1) string {
	name := envOrFromReq(req, "NON_BLOCKING_LOG_FILE", "NON_BLOCKING_LOG.md")
	if filepath.IsAbs(name) {
		return name
	}
	return filepath.Join(projectDir, name)
}

func cleanupReportPath(req *proto.StageRequestV1) string {
	tekhtonDir := envOr("TEKHTON_DIR", ".tekhton")
	name := envOr("CLEANUP_REPORT_FILE", filepath.Join(tekhtonDir, "CLEANUP_REPORT.md"))
	if filepath.IsAbs(name) {
		return name
	}
	projectDir := resolveProjectDir(req)
	return filepath.Join(projectDir, name)
}

func archiveReport(reportPath string, req *proto.StageRequestV1) {
	logDir := envOr("LOG_DIR", ".claude/logs")
	ts := envOr("TIMESTAMP", "")
	if ts == "" {
		// No timestamp — leave the report in place (matches bash's
		// `|| true` tolerance for missing globals).
		return
	}
	if !filepath.IsAbs(logDir) {
		projectDir := resolveProjectDir(req)
		logDir = filepath.Join(projectDir, logDir)
	}
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return
	}
	dest := filepath.Join(logDir, ts+"_"+filepath.Base(reportPath))
	_ = os.Rename(reportPath, dest)
}

func renderCleanupPrompt(req *proto.StageRequestV1, batch []*notes.Note) (string, error) {
	items := strings.Builder{}
	for _, n := range batch {
		items.WriteString("- ")
		items.WriteString(n.Title)
		items.WriteString("\n")
	}
	vars := map[string]string{
		"CLEANUP_ITEMS":      strings.TrimRight(items.String(), "\n"),
		"CLEANUP_ITEM_COUNT": fmt.Sprintf("%d", len(batch)),
	}
	promptsDir := resolvePromptsDir(req)
	return prompt.Render(promptsDir, "cleanup", vars)
}

// readModifiedFilesFromCoderSummary parses `## Files Created` /
// `## Files Modified` sections of CODER_SUMMARY.md so SelectCleanupBatch
// can prioritise notes overlapping with this run's work. Mirrors the
// awk pipeline in stages/cleanup.sh:52-56.
func readModifiedFilesFromCoderSummary(projectDir string) []string {
	summaryPath := envOr("CODER_SUMMARY_FILE", ".tekhton/CODER_SUMMARY.md")
	if !filepath.IsAbs(summaryPath) {
		summaryPath = filepath.Join(projectDir, summaryPath)
	}
	raw, err := os.ReadFile(summaryPath)
	if err != nil {
		return nil
	}
	var out []string
	inSection := false
	for _, line := range strings.Split(string(raw), "\n") {
		if strings.HasPrefix(line, "## Files Created") || strings.HasPrefix(line, "## Files Modified") {
			inSection = true
			continue
		}
		if inSection && strings.HasPrefix(line, "##") {
			inSection = false
			continue
		}
		if !inSection {
			continue
		}
		t := strings.TrimSpace(line)
		if !(strings.HasPrefix(t, "- ") || strings.HasPrefix(t, "* ")) {
			continue
		}
		t = strings.TrimPrefix(t, "- ")
		t = strings.TrimPrefix(t, "* ")
		// Bash stripped everything after the first space (file ... or
		// file (NEW) annotations).
		if idx := strings.Index(t, " "); idx >= 0 {
			t = t[:idx]
		}
		// Strip leading/trailing backticks from markdown-quoted paths.
		t = strings.Trim(t, "`")
		if t != "" {
			out = append(out, t)
		}
	}
	return out
}

// revertCleanupOnlyFiles checks out only those files modified by the
// cleanup agent — i.e. files present after the agent runs but absent
// from preCleanup. Mirrors stages/cleanup.sh:124-132 verbatim so
// primary-pipeline changes are preserved.
func revertCleanupOnlyFiles(projectDir string, preCleanup []string) {
	post, err := gitDiffNameOnly()
	if err != nil {
		return
	}
	preSet := map[string]struct{}{}
	for _, f := range preCleanup {
		preSet[f] = struct{}{}
	}
	for _, f := range post {
		if _, alreadyDirty := preSet[f]; alreadyDirty {
			continue
		}
		cmd := exec.Command("git", "checkout", "--", f)
		if projectDir != "" {
			cmd.Dir = projectDir
		}
		_ = cmd.Run()
	}
}

func gitDiffNameOnly() ([]string, error) {
	out, err := exec.Command("git", "diff", "--name-only").Output()
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	cleaned := make([]string, 0, len(lines))
	for _, l := range lines {
		l = strings.TrimSpace(l)
		if l != "" {
			cleaned = append(cleaned, l)
		}
	}
	return cleaned, nil
}

func skipResult(req *proto.StageRequestV1, reason string) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictSkip,
		ExitReason: reason,
	}
}

func resolveProjectDir(req *proto.StageRequestV1) string {
	if v := envOrFromReq(req, "PROJECT_DIR", ""); v != "" {
		return v
	}
	wd, _ := os.Getwd()
	return wd
}

func resolvePromptsDir(req *proto.StageRequestV1) string {
	if v := envOrFromReq(req, "TEKHTON_HOME", ""); v != "" {
		return filepath.Join(v, "prompts")
	}
	return "prompts"
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}
