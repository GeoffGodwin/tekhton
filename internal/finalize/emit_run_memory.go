package finalize

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// EmitRunMemory is the Go body of _hook_emit_run_memory. Appends a JSONL
// record to RUN_MEMORY.jsonl summarizing the run's task, milestone, files
// touched, verdict, duration, and agent-call count. Pure Go because the
// inputs are RunResultV1 + git diff + project config — no notes/drift/
// dashboard subsystem dependencies.
//
// FIFO prune: after each append the file is truncated to the most recent
// RUN_MEMORY_MAX_ENTRIES lines (default 50), matching the bash behavior.
type EmitRunMemory struct {
	// Path overrides the default RUN_MEMORY.jsonl location.
	Path string

	// MaxEntries overrides RUN_MEMORY_MAX_ENTRIES (default 50). Negative
	// disables pruning entirely.
	MaxEntries int

	// Git overrides the git command used to capture changed files. Tests
	// substitute a stub.
	Git func(dir string, args ...string) ([]byte, error)
}

// Name implements Hook.
func (h *EmitRunMemory) Name() string { return "_hook_emit_run_memory" }

// runMemoryRecord is the JSONL shape emitted per run. Mirrors the bash
// printf field list at lib/run_memory.sh:193 — the field names and order
// are part of the contract intake history reads.
type runMemoryRecord struct {
	RunID           string          `json:"run_id"`
	Milestone       string          `json:"milestone"`
	Task            string          `json:"task"`
	FilesTouched    []string        `json:"files_touched"`
	Decisions       json.RawMessage `json:"decisions"`
	ReworkReasons   json.RawMessage `json:"rework_reasons"`
	TestOutcomes    testOutcomes    `json:"test_outcomes"`
	DurationSeconds int64           `json:"duration_seconds"`
	AgentCalls      int             `json:"agent_calls"`
	Verdict         string          `json:"verdict"`
}

type testOutcomes struct {
	Passed  int `json:"passed"`
	Failed  int `json:"failed"`
	Skipped int `json:"skipped"`
}

// Run appends one JSONL record and prunes the file. Returns nil for missing
// log directory (creates it) or empty inputs — the bash version was equally
// forgiving.
func (h *EmitRunMemory) Run(_ context.Context, in *Input) error {
	logDir := in.LogDir
	if logDir == "" {
		logDir = filepath.Join(in.ProjectDir, ".claude", "logs")
	}
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return fmt.Errorf("emit_run_memory: mkdir log dir: %w", err)
	}
	path := h.Path
	if path == "" {
		path = filepath.Join(logDir, "RUN_MEMORY.jsonl")
	}

	rec := h.buildRecord(in)
	line, err := json.Marshal(&rec)
	if err != nil {
		return fmt.Errorf("emit_run_memory: marshal: %w", err)
	}
	if err := appendLine(path, line); err != nil {
		return fmt.Errorf("emit_run_memory: append: %w", err)
	}
	maxEntries := h.MaxEntries
	if maxEntries == 0 {
		maxEntries = lookupIntEnv("RUN_MEMORY_MAX_ENTRIES", 50)
	}
	if maxEntries > 0 {
		if err := pruneJSONL(path, maxEntries); err != nil {
			return fmt.Errorf("emit_run_memory: prune: %w", err)
		}
	}
	return nil
}

func (h *EmitRunMemory) buildRecord(in *Input) runMemoryRecord {
	ts := in.Timestamp
	if ts == "" {
		ts = time.Now().UTC().Format("20060102_150405")
	}
	verdict := "PASS"
	if in.ExitCode != 0 {
		verdict = "FAIL"
	}
	task := os.Getenv("TASK")
	if len(task) > 200 {
		task = task[:200]
	}
	milestone := in.Milestone
	if milestone == "" {
		milestone = "none"
	}

	files := h.changedFiles(in.ProjectDir)

	duration := int64(0)
	agentCalls := 0
	if in.Result != nil {
		duration = in.Result.ElapsedSecs
		agentCalls = in.Result.AgentCalls
	}
	if envDur := lookupIntEnv("_ORCH_ELAPSED", 0); duration == 0 && envDur > 0 {
		duration = int64(envDur)
	}
	if envCalls := lookupIntEnv("_ORCH_AGENT_CALLS", 0); agentCalls == 0 && envCalls > 0 {
		agentCalls = envCalls
	}

	return runMemoryRecord{
		RunID:           "run_" + ts,
		Milestone:       milestone,
		Task:            task,
		FilesTouched:    files,
		Decisions:       json.RawMessage("[]"),
		ReworkReasons:   json.RawMessage("[]"),
		TestOutcomes:    testOutcomes{},
		DurationSeconds: duration,
		AgentCalls:      agentCalls,
		Verdict:         verdict,
	}
}

// changedFiles runs `git diff --name-only HEAD` in projectDir. Errors are
// swallowed (not in a git repo, no HEAD ref, etc.) — the bash version did
// the same with `|| true`.
func (h *EmitRunMemory) changedFiles(projectDir string) []string {
	runner := h.Git
	if runner == nil {
		runner = defaultGit
	}
	out, err := runner(projectDir, "diff", "--name-only", "HEAD")
	if err != nil {
		return nil
	}
	var files []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		files = append(files, line)
	}
	return files
}

func defaultGit(dir string, args ...string) ([]byte, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	return cmd.Output()
}

// appendLine appends data + '\n' to path. Creates the file if missing.
func appendLine(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.Write(data); err != nil {
		return err
	}
	_, err = f.Write([]byte("\n"))
	return err
}

// pruneJSONL truncates path to the most recent max lines via tmpfile +
// rename. Mirrors the bash `tail -n +N | mv` pattern.
func pruneJSONL(path string, max int) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	var lines []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	if err := sc.Err(); err != nil {
		return err
	}
	if len(lines) <= max {
		return nil
	}
	keep := lines[len(lines)-max:]
	tmp := path + ".tmp"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	for _, line := range keep {
		if _, err := out.WriteString(line + "\n"); err != nil {
			out.Close()
			_ = os.Remove(tmp)
			return err
		}
	}
	if err := out.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

// lookupIntEnv reads an integer from the environment, returning fallback
// on missing/invalid values.
func lookupIntEnv(name string, fallback int) int {
	raw, ok := os.LookupEnv(name)
	if !ok || raw == "" {
		return fallback
	}
	n, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil {
		return fallback
	}
	return n
}
