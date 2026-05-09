// Package stagerunner runs a single Tekhton pipeline stage as a bash
// subprocess and decodes its stage.result.v1 envelope.
//
// m18 introduces this package as the seam between the Go runner
// (internal/pipeline) and the bash stage scripts (stages/*.sh). The bash
// front-end of m12 drove stages in-process; m18 inverts the relationship —
// the Go runner exec's bash to source a stage script, with all communication
// flowing through two JSON files (TEKHTON_STAGE_REQUEST_FILE and
// TEKHTON_STAGE_RESULT_FILE).
//
// The adapter uses os/exec directly (not internal/supervisor) — stages are
// heavier than agent calls and have different failure semantics. A stage
// that crashes is a pipeline failure, not a transient.
package stagerunner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// Sentinel errors callers match with errors.Is.
var (
	// ErrUnknownStage is returned when the request names a stage with no
	// registered script path.
	ErrUnknownStage = errors.New("stagerunner: unknown stage")

	// ErrMissingResultFile is returned when the bash subprocess exits
	// without writing the result file (or writes an empty file).
	ErrMissingResultFile = errors.New("stagerunner: missing result file")

	// ErrInvalidResult is returned when the result file does not parse as
	// stage.result.v1.
	ErrInvalidResult = errors.New("stagerunner: invalid result envelope")

	// ErrSubprocess wraps a non-zero subprocess exit when no stage.result.v1
	// is present (so the caller sees something more specific than os/exec's
	// "exit status N").
	ErrSubprocess = errors.New("stagerunner: subprocess failed")
)

// Adapter runs a stage and reports the structured outcome.
type Adapter interface {
	Run(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error)
}

// BashAdapter exec's a bash subprocess that recreates the legacy V3 shell
// environment (lib/common.sh + DefaultLibHelpers + per-stage Helpers +
// lib/stage_envelope.sh), sources the matching stage script, then calls
// run_stage_<name>. The stage tail block (lib/stage_envelope.sh) writes the
// result envelope.
type BashAdapter struct {
	// TekhtonHome is the Tekhton repo root (where lib/ and stages/ live).
	TekhtonHome string

	// ProjectDir is the target project. Becomes the subprocess CWD.
	ProjectDir string

	// Stages maps a stage name to its definition (script path + extra
	// per-stage lib helpers). Defaults to DefaultStageDefs.
	Stages map[string]StageDef

	// LibHelpers overrides the common base set of lib/*.sh files sourced for
	// every stage. nil (the zero value) means use DefaultLibHelpers; pass an
	// empty slice ([]string{}) to source nothing — useful in tests with a
	// stub harness that only contains common.sh and stage_envelope.sh.
	LibHelpers []string

	// TekhtonBin is the absolute path to the tekhton binary the bash side
	// shells back into via `tekhton stage emit`. Defaults to "tekhton" on
	// PATH.
	TekhtonBin string

	// BashBin overrides the bash binary path. Defaults to "/bin/bash".
	BashBin string

	// Now overrides the wall-clock for duration measurement. Tests inject
	// a fixed clock to assert duration math without sleeping.
	Now func() time.Time

	// LogWriter, when non-nil, receives the subprocess stdout/stderr stream
	// in addition to the file at req.LogFile. Tests use this to assert on
	// what the bash side printed.
	LogWriter io.Writer
}

// stageEntryFunc names the bash function each stage script defines for the
// runner to call. Same identifier across stages (run_stage_<name>) so this
// stays mechanical.
func stageEntryFunc(stage string) string {
	return "run_stage_" + stage
}

// stageDefFor returns the definition for a stage, falling back to
// DefaultStageDefs when Stages is nil or missing the entry.
func (a *BashAdapter) stageDefFor(stage string) (StageDef, bool) {
	if a.Stages != nil {
		if d, ok := a.Stages[stage]; ok && d.Script != "" {
			return d, true
		}
	}
	if d, ok := DefaultStageDefs[stage]; ok {
		return d, true
	}
	return StageDef{}, false
}

// libHelpers returns the common base helper list. nil means use
// DefaultLibHelpers; explicit []string{} means source nothing.
func (a *BashAdapter) libHelpers() []string {
	if a.LibHelpers == nil {
		return DefaultLibHelpers
	}
	return a.LibHelpers
}

// Run executes the stage and returns the parsed envelope. Lifecycle:
//
//  1. Validate the request envelope.
//  2. Resolve the script path for the stage.
//  3. Write the request to a temp file the stage can read via
//     TEKHTON_STAGE_REQUEST_FILE; resolve the result-file path the stage
//     writes via TEKHTON_STAGE_RESULT_FILE.
//  4. exec.CommandContext bash with the stage source-and-call snippet.
//  5. On exit: read the result file, parse and validate, return.
//
// SIGINT and parent-context cancellation propagate via exec.CommandContext —
// same pattern as internal/supervisor.
func (a *BashAdapter) Run(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	if req == nil {
		return nil, fmt.Errorf("%w: nil request", proto.ErrInvalidStageRequest)
	}
	if err := req.Validate(); err != nil {
		return nil, err
	}

	def, ok := a.stageDefFor(req.Stage)
	if !ok {
		return nil, fmt.Errorf("%w: %q", ErrUnknownStage, req.Stage)
	}
	scriptPath := def.Script
	if !filepath.IsAbs(scriptPath) {
		scriptPath = filepath.Join(a.TekhtonHome, def.Script)
	}

	requestFile, err := writeRequestFile(req)
	if err != nil {
		return nil, fmt.Errorf("stagerunner: write request file: %w", err)
	}
	defer os.Remove(requestFile)

	resultFile := req.ResultFile
	// Pre-create the directory but NOT the file — the stage tail block
	// writes it. An empty file means the tail block did not run.
	if dir := filepath.Dir(resultFile); dir != "" {
		_ = os.MkdirAll(dir, 0o755)
	}
	_ = os.Remove(resultFile)

	bashBin := a.BashBin
	if bashBin == "" {
		bashBin = "/bin/bash"
	}

	bashScript := buildBashScript(a.TekhtonHome, a.ProjectDir, scriptPath, req.Stage, a.libHelpers(), def.Helpers)

	cmd := exec.CommandContext(ctx, bashBin, "-c", bashScript)
	cmd.Dir = a.ProjectDir
	cmd.Env = a.buildEnv(req, requestFile)

	// Stream output to LogFile + LogWriter.
	logSinks, closeLog, err := a.openLogSinks(req.LogFile)
	if err != nil {
		return nil, fmt.Errorf("stagerunner: open log sinks: %w", err)
	}
	defer closeLog()
	cmd.Stdout = logSinks
	cmd.Stderr = logSinks

	now := a.Now
	if now == nil {
		now = time.Now
	}
	start := now()
	runErr := cmd.Run()
	duration := int(now().Sub(start).Seconds())

	res, parseErr := readResultFile(resultFile)
	if parseErr != nil {
		// No envelope — synthesize a fail result with what we know.
		if runErr != nil {
			return failResult(req, fmt.Sprintf("subprocess error: %v", runErr), duration), errors.Join(ErrSubprocess, runErr)
		}
		return failResult(req, parseErr.Error(), duration), parseErr
	}

	// Stage produced an envelope. The subprocess may still have exited
	// non-zero — surface that via the wrapped error so the runner can decide
	// what to do, but return the envelope so verdict/exit_reason are visible.
	if runErr != nil {
		return res, fmt.Errorf("%w: %v", ErrSubprocess, runErr)
	}
	return res, nil
}

// buildEnv returns the env block for the bash subprocess: parent env minus
// TEKHTON_STAGE_* (we always set our own), plus request-file path,
// result-file path, log-file path, tekhton-bin path, and the request's
// EnvOverrides.
func (a *BashAdapter) buildEnv(req *proto.StageRequestV1, requestFile string) []string {
	parent := os.Environ()
	out := make([]string, 0, len(parent)+8)
	// Skip the TEKHTON_STAGE_* keys we own; we always set our own values
	// below. Keep TEKHTON_BIN from the parent — only drop it if the
	// adapter explicitly overrides it, handled later in this function.
	skip := map[string]bool{
		"TEKHTON_STAGE_REQUEST_FILE": true,
		"TEKHTON_STAGE_RESULT_FILE":  true,
		"TEKHTON_STAGE_LOG_FILE":     true,
		"TEKHTON_STAGE_NAME":         true,
	}
	if a.TekhtonBin != "" {
		skip["TEKHTON_BIN"] = true
	}
	for _, kv := range parent {
		k := envKey(kv)
		if skip[k] {
			continue
		}
		// Drop EnvOverrides keys from parent so the override below wins.
		if _, ok := req.EnvOverrides[k]; ok {
			continue
		}
		out = append(out, kv)
	}
	out = append(out,
		"TEKHTON_STAGE_REQUEST_FILE="+requestFile,
		"TEKHTON_STAGE_RESULT_FILE="+req.ResultFile,
		"TEKHTON_STAGE_NAME="+req.Stage,
	)
	if req.LogFile != "" {
		out = append(out, "TEKHTON_STAGE_LOG_FILE="+req.LogFile)
	}
	if a.TekhtonBin != "" {
		out = append(out, "TEKHTON_BIN="+a.TekhtonBin)
	}
	for k, v := range req.EnvOverrides {
		if k == "" {
			continue
		}
		out = append(out, k+"="+v)
	}
	return out
}

// envKey returns the key portion of a "K=V" environment string.
func envKey(kv string) string {
	for i := 0; i < len(kv); i++ {
		if kv[i] == '=' {
			return kv[:i]
		}
	}
	return kv
}

// openLogSinks resolves the log destination. When req.LogFile is non-empty we
// append to it; we also tee to LogWriter when set. Returns a closer that
// flushes / closes the file.
func (a *BashAdapter) openLogSinks(logFile string) (io.Writer, func(), error) {
	if logFile == "" && a.LogWriter == nil {
		return io.Discard, func() {}, nil
	}
	if logFile == "" {
		return a.LogWriter, func() {}, nil
	}
	if dir := filepath.Dir(logFile); dir != "" {
		_ = os.MkdirAll(dir, 0o755)
	}
	f, err := os.OpenFile(logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, nil, err
	}
	if a.LogWriter == nil {
		return f, func() { _ = f.Close() }, nil
	}
	return io.MultiWriter(f, a.LogWriter), func() { _ = f.Close() }, nil
}

// writeRequestFile serializes req to a temp file and returns its path.
func writeRequestFile(req *proto.StageRequestV1) (string, error) {
	b, err := json.MarshalIndent(req, "", "  ")
	if err != nil {
		return "", err
	}
	f, err := os.CreateTemp("", "tekhton-stage-req-*.json")
	if err != nil {
		return "", err
	}
	if _, err := f.Write(b); err != nil {
		_ = f.Close()
		return "", err
	}
	if err := f.Close(); err != nil {
		return "", err
	}
	return f.Name(), nil
}

// readResultFile reads and validates the envelope at path.
func readResultFile(path string) (*proto.StageResultV1, error) {
	if path == "" {
		return nil, fmt.Errorf("%w: result_file is empty", ErrMissingResultFile)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%w: %s", ErrMissingResultFile, path)
		}
		return nil, fmt.Errorf("stagerunner: read result file: %w", err)
	}
	if len(b) == 0 {
		return nil, fmt.Errorf("%w: empty file %s", ErrMissingResultFile, path)
	}
	res := &proto.StageResultV1{}
	if err := json.Unmarshal(b, res); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidResult, err)
	}
	if err := res.Validate(); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidResult, err)
	}
	return res, nil
}

// buildBashScript renders the bash wrapper that recreates the V3 environment
// for a single stage call:
//
//  1. lib/common.sh — colors, log/warn/error/header/success.
//  2. DefaultLibHelpers (or override) — the global lib/*.sh source list from
//     legacy tekhton.sh; stage scripts call into many of these helpers.
//  3. Per-stage Helpers — stage-specific lib/*.sh files (e.g. intake_helpers.sh).
//  4. lib/stage_envelope.sh — emit_stage_envelope used by the stage tail.
//  5. The stage script itself.
//  6. run_stage_<name> — the stage entry point.
//
// Paths in libHelpers / stageHelpers are resolved relative to TEKHTON_HOME
// when not absolute. Quoting via %q escapes any special characters safely.
func buildBashScript(tekhtonHome, projectDir, scriptPath, stage string, libHelpers, stageHelpers []string) string {
	var b strings.Builder
	b.WriteString("set -euo pipefail\n")
	fmt.Fprintf(&b, "export TEKHTON_HOME=%q\n", tekhtonHome)
	fmt.Fprintf(&b, "cd %q\n", projectDir)
	b.WriteString(`source "$TEKHTON_HOME/lib/common.sh"` + "\n")
	for _, h := range libHelpers {
		writeSourceLine(&b, tekhtonHome, h)
	}
	for _, h := range stageHelpers {
		writeSourceLine(&b, tekhtonHome, h)
	}
	b.WriteString(`source "$TEKHTON_HOME/lib/stage_envelope.sh"` + "\n")
	fmt.Fprintf(&b, "source %q\n", scriptPath)
	fmt.Fprintf(&b, "%s\n", stageEntryFunc(stage))
	return b.String()
}

// writeSourceLine appends a `source <path>` line to b. Relative paths are
// resolved against tekhtonHome; absolute paths are sourced as-is.
func writeSourceLine(b *strings.Builder, tekhtonHome, path string) {
	if path == "" {
		return
	}
	if !filepath.IsAbs(path) {
		path = filepath.Join(tekhtonHome, path)
	}
	fmt.Fprintf(b, "source %q\n", path)
}

// failResult builds a synthetic stage.result.v1 with verdict=fail when the
// subprocess crashed before writing its own envelope.
func failResult(req *proto.StageRequestV1, reason string, duration int) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:       proto.StageResultProtoV1,
		Stage:       req.Stage,
		Verdict:     proto.VerdictFail,
		ExitReason:  reason,
		DurationSec: duration,
		Error:       reason,
	}
}
