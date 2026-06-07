// Package tdd implements the TDD write-failing pre-flight tester sub-stage.
//
// m38.2 ports stages/tester_tdd.sh::_run_tester_write_failing to Go. The
// bash file remains on disk at m38.2 close — the bash dispatch in
// stages/tester.sh continues to call _run_tester_write_failing until m38.6
// rewires the dispatch to call tdd.Run directly and deletes the bash.
//
// Load-bearing semantics preserved here:
//
//  1. UPSTREAM agent errors return a non-nil error so the pipeline halts.
//     The bash version at stages/tester_tdd.sh:74-86 calls `exit 1` after
//     writing pipeline state; the Go equivalent returns a non-nil error so
//     stagerunner can surface it to the outer loop. This is the m38
//     regression-canary — see TestRun_UpstreamReturnsNonNilError.
//
//  2. Null-run is non-fatal. The bash version at lines 89-92 warns and
//     returns; the Go port returns nil error with Result.NullRun=true so
//     the caller (m38.6's RunStage) can fall back to "coder proceeds
//     without pre-written tests".
//
//  3. Preflight file archival is best-effort. The bash `cp` is replaced
//     with Go-native io.Copy; archival failure is logged but does not flip
//     the success outcome.
package tdd

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/geoffgodwin/tekhton/internal/prompt"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/state"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
	"github.com/geoffgodwin/tekhton/internal/tester"
)

// Default values for Options fields. Mirror the bash ${VAR:-DEFAULT}
// pattern in stages/tester_tdd.sh.
const (
	DefaultMaxTurns           = 10
	DefaultModel              = "claude-sonnet-4-6"
	DefaultPreflightFile      = ".tekhton/TESTER_PREFLIGHT.md"
	DefaultLogDir             = ".claude/logs"
	defaultPipelineStatePath  = ".claude/PIPELINE_STATE.md"
	defaultArchitectureNotice = "(ARCHITECTURE.md not found)"
)

// Options carries the per-run knobs for tdd.Run. Empty fields fall back to
// the Default* constants above. The struct mirrors the env-driven contract
// in stages/tester_tdd.sh: MaxTurns ← TESTER_WRITE_FAILING_MAX_TURNS,
// Model ← CLAUDE_TESTER_MODEL, etc.
type Options struct {
	MaxTurns      int
	Model         string
	AgentTools    string
	PreflightFile string
	LogDir        string
	Timestamp     string
}

// Request bundles everything tdd.Run needs from the surrounding pipeline.
// Path fields may be relative or absolute; relative paths are resolved
// against ProjectDir at the seams that touch the filesystem.
type Request struct {
	ProjectDir          string
	TekhtonHome         string
	PromptsDir          string
	Task                string
	ArchitectureContent string
	RepoMapContent      string
	MilestoneBlock      string

	HumanMode      bool
	HumanNotesTag  string
	MilestoneMode  bool
	StateFile      string
	PromptVarsBase map[string]string

	Options Options
}

// Result reports what happened during a tdd.Run invocation. Callers
// inspect NullRun to decide whether to fall back to "coder proceeds
// without pre-written tests"; PreflightExists confirms the artifact was
// produced (the on-disk file at Options.PreflightFile).
type Result struct {
	Timing          tester.TesterTiming
	PreflightExists bool
	NullRun         bool
	AgentExitCode   int
	Turns           int
	DurationS       int
	ArchivePath     string
}

// AgentRunner is the seam between tdd.Run and the supervisor. Production
// wires the in-process supervisor; tests inject a fake to drive the
// UPSTREAM, null-run, and success branches deterministically.
type AgentRunner interface {
	Run(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error)
}

// PromptRenderer is the seam used to produce the rendered prompt body.
// Default delegates to internal/prompt; tests inject a fake to avoid
// needing the prompt template on disk.
type PromptRenderer interface {
	Render(promptsDir, name string, vars map[string]string) (string, error)
}

// StateWriter is the seam tdd.Run uses to persist the resume context
// before returning the UPSTREAM error. The default implementation wraps
// state.Store. Tests inject a fake to assert the call was made.
type StateWriter interface {
	WriteHalt(ctx context.Context, stage, exitReason, resumeFlag, task, notes string) error
}

var (
	agentRunner    AgentRunner    = supervisor.New(nil, nil)
	promptRenderer PromptRenderer = defaultPromptRenderer{}
	stateWriter    StateWriter    = defaultStateWriter{}
)

// SetAgentRunner overrides the supervisor seam. Returns the previous
// runner so tests can defer-restore.
func SetAgentRunner(r AgentRunner) AgentRunner {
	prev := agentRunner
	agentRunner = r
	return prev
}

// SetPromptRenderer overrides the prompt-render seam.
func SetPromptRenderer(r PromptRenderer) PromptRenderer {
	prev := promptRenderer
	promptRenderer = r
	return prev
}

// SetStateWriter overrides the state-writer seam.
func SetStateWriter(w StateWriter) StateWriter {
	prev := stateWriter
	stateWriter = w
	return prev
}

// Run executes the TDD write-failing pre-flight. Returns a non-nil error
// ONLY when the agent reports an UPSTREAM error (regression-canary —
// matches `exit 1` semantics from stages/tester_tdd.sh:85). Null-run is
// non-fatal: returns nil with Result.NullRun=true.
func Run(ctx context.Context, req *Request) (*Result, error) {
	if req == nil {
		return nil, fmt.Errorf("tdd: nil request")
	}
	opts := withDefaults(req.Options)
	startedAt := time.Now()

	body, err := renderPrompt(req)
	if err != nil {
		return nil, fmt.Errorf("tdd: render prompt: %w", err)
	}

	promptFile, cleanup, err := writePromptTmpFile(body)
	if err != nil {
		return nil, fmt.Errorf("tdd: write prompt: %w", err)
	}
	defer cleanup()

	agentReq := &proto.AgentRequestV1{
		Proto:        proto.AgentRequestProtoV1,
		Label:        "Tester (TDD pre-flight)",
		Model:        opts.Model,
		MaxTurns:     opts.MaxTurns,
		PromptFile:   promptFile,
		WorkingDir:   req.ProjectDir,
		AllowedTools: opts.AgentTools,
	}
	agentRes, agentErr := agentRunner.Run(ctx, agentReq)
	if agentErr != nil {
		return nil, fmt.Errorf("tdd: agent invocation: %w", agentErr)
	}

	// --- UPSTREAM error check (regression-canary) ---
	if agentRes != nil && agentRes.ErrorCategory == supervisor.CategoryUpstream {
		resumeFlag := buildResumeFlag("test", req)
		subcat := agentRes.ErrorSubcategory
		if subcat == "" {
			subcat = "unknown"
		}
		exitReason := "TDD pre-flight API error: " + subcat
		_ = stateWriter.WriteHalt(ctx, "tester", exitReason, resumeFlag, req.Task,
			"UPSTREAM error during TDD write-failing phase")
		return nil, fmt.Errorf("tdd pre-flight upstream error (%s): %s",
			subcat, agentRes.ErrorMessage)
	}

	out := &Result{}
	if agentRes != nil {
		out.AgentExitCode = agentRes.ExitCode
		out.Turns = agentRes.TurnsUsed
	}
	out.DurationS = int(time.Since(startedAt) / time.Second)

	// --- Null-run detection — non-fatal in TDD ---
	if isNullRun(agentRes) {
		out.NullRun = true
		return out, nil
	}

	// --- Validate output file existence + archive ---
	preflightPath := resolveProjectPath(req.ProjectDir, opts.PreflightFile)
	if pathExists(preflightPath) {
		out.PreflightExists = true
		archived, archErr := archivePreflight(preflightPath, opts, req.ProjectDir)
		if archErr == nil {
			out.ArchivePath = archived
		}
	}

	// --- Parse timing in replace mode against the preflight file ---
	out.Timing = tester.ParseTesterTiming(preflightPath, tester.ParseModeReplace)
	return out, nil
}

// withDefaults fills Options' empty fields from the Default* constants.
func withDefaults(o Options) Options {
	if o.MaxTurns <= 0 {
		o.MaxTurns = DefaultMaxTurns
	}
	if o.Model == "" {
		o.Model = DefaultModel
	}
	if o.PreflightFile == "" {
		o.PreflightFile = DefaultPreflightFile
	}
	if o.LogDir == "" {
		o.LogDir = DefaultLogDir
	}
	return o
}

// renderPrompt assembles the variable map and dispatches to the prompt
// engine. Mirrors stages/tester_tdd.sh:38-45 — architecture + repo map +
// milestone block are exported into the variable map before render.
func renderPrompt(req *Request) (string, error) {
	vars := map[string]string{}
	for k, v := range req.PromptVarsBase {
		vars[k] = v
	}
	arch := req.ArchitectureContent
	if arch == "" {
		arch = defaultArchitectureNotice
	}
	vars["ARCHITECTURE_CONTENT"] = arch
	vars["REPO_MAP_CONTENT"] = req.RepoMapContent
	vars["MILESTONE_BLOCK"] = req.MilestoneBlock
	if _, ok := vars["TASK"]; !ok {
		vars["TASK"] = req.Task
	}
	return promptRenderer.Render(req.PromptsDir, "tester_write_failing", vars)
}

// writePromptTmpFile materializes the rendered prompt to disk so the
// supervisor can pass it to the agent CLI via --prompt-file. The cleanup
// closure removes the temp file when the caller is done.
func writePromptTmpFile(content string) (string, func(), error) {
	f, err := os.CreateTemp("", "tekhton-tdd-prompt-*.md")
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

// archivePreflight copies the preflight file to LogDir with the
// timestamped basename. Mirrors stages/tester_tdd.sh:97-98. Failure is
// best-effort — returns the error but the stage outcome stays success.
func archivePreflight(srcPath string, opts Options, projectDir string) (string, error) {
	logDir := resolveProjectPath(projectDir, opts.LogDir)
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return "", err
	}
	base := filepath.Base(opts.PreflightFile)
	if opts.Timestamp != "" {
		base = opts.Timestamp + "_" + base
	}
	dstPath := filepath.Join(logDir, base)

	src, err := os.Open(srcPath)
	if err != nil {
		return "", err
	}
	defer src.Close()

	dst, err := os.Create(dstPath)
	if err != nil {
		return "", err
	}
	defer dst.Close()

	if _, err := io.Copy(dst, src); err != nil {
		_ = os.Remove(dstPath)
		return "", err
	}
	return dstPath, nil
}

// buildResumeFlag mirrors lib/state.sh::_build_resume_flag with start_at
// fixed to "test" (matches stages/tester_tdd.sh:77).
func buildResumeFlag(startAt string, req *Request) string {
	flag := ""
	switch {
	case req.HumanMode:
		flag = "--human"
		if req.HumanNotesTag != "" {
			flag = flag + " " + req.HumanNotesTag
		}
	case req.MilestoneMode:
		flag = "--milestone"
	}
	if flag == "" {
		return "--start-at " + startAt
	}
	return flag + " --start-at " + startAt
}

// resolveProjectPath joins relative paths under projectDir. Absolute
// paths are returned unchanged. Empty input returns empty output.
func resolveProjectPath(projectDir, path string) string {
	if path == "" || filepath.IsAbs(path) {
		return path
	}
	if projectDir == "" {
		return path
	}
	return filepath.Join(projectDir, path)
}

// pathExists reports whether path is a regular file.
func pathExists(path string) bool {
	if path == "" {
		return false
	}
	fi, err := os.Stat(path)
	if err != nil {
		return false
	}
	return !fi.IsDir()
}

// isNullRun ports the bash `was_null_run` predicate. A nil result is
// treated as null so a supervisor failure before the result is built
// does not get classified as real work — matches
// supervisor.AgentResult.IsNullRun semantics.
func isNullRun(res *proto.AgentResultV1) bool {
	if res == nil {
		return true
	}
	return supervisor.FromProto(res).IsNullRun()
}

// defaultPromptRenderer delegates to internal/prompt.Render.
type defaultPromptRenderer struct{}

func (defaultPromptRenderer) Render(promptsDir, name string, vars map[string]string) (string, error) {
	return prompt.Render(promptsDir, name, vars)
}

// defaultStateWriter wraps state.Store. The PIPELINE_STATE_FILE env var
// or the bash default determines the snapshot path.
type defaultStateWriter struct{}

func (defaultStateWriter) WriteHalt(_ context.Context, stage, exitReason, resumeFlag, task, notes string) error {
	path := os.Getenv("PIPELINE_STATE_FILE")
	if path == "" {
		path = defaultPipelineStatePath
	}
	if !filepath.IsAbs(path) {
		if pd := os.Getenv("PROJECT_DIR"); pd != "" {
			path = filepath.Join(pd, path)
		}
	}
	store := state.New(path)
	return store.Update(func(snap *proto.StateSnapshotV1) {
		snap.ExitStage = stage
		snap.ExitReason = exitReason
		snap.ResumeFlag = strings.TrimSpace(resumeFlag)
		snap.ResumeTask = task
		snap.Notes = notes
	})
}
