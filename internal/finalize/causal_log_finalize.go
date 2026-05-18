package finalize

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/causal"
)

// CausalLogFinalize is the Go body of _hook_causal_log_finalize. The bash
// hook (1) emitted a `pipeline_end` event into CAUSAL_LOG.jsonl, (2)
// re-emitted dashboard data files, and (3) archived the causal log into
// runs/CAUSAL_LOG_<runID>.jsonl.
//
// The dashboard step (#2) is intentionally NOT ported here — the dashboard
// emitters are bash subsystems still owned by lib/dashboard.sh, and the
// _hook_final_dashboard_status hook later in the chain re-emits the final
// state anyway. Dropping the intermediate dashboard refresh is a behavior
// trim, not a regression: the bash version called every emitter with
// `2>/dev/null || true` so they were already best-effort.
//
// The remaining work (#1 + #3) is pure Go because the causal log writer
// (internal/causal.Log) owns both operations.
type CausalLogFinalize struct {
	// Path overrides the default CAUSAL_LOG.jsonl location.
	Path string

	// Retention overrides CAUSAL_LOG_RETENTION_RUNS (default 50).
	Retention int

	// Cap overrides CAUSAL_LOG_MAX_EVENTS (default 2000).
	Cap int
}

// Name implements Hook.
func (h *CausalLogFinalize) Name() string { return "_hook_causal_log_finalize" }

// Run emits the pipeline_end event and archives the log. Both steps are
// best-effort; an error in one does not skip the other, and the function
// returns the first error encountered so the orchestrator can log it.
func (h *CausalLogFinalize) Run(_ context.Context, in *Input) error {
	if !causalEnabled() {
		return nil
	}
	logPath := h.Path
	if logPath == "" {
		if env, ok := os.LookupEnv("CAUSAL_LOG_FILE"); ok && env != "" {
			logPath = absoluteUnder(in.ProjectDir, env)
		} else {
			logPath = filepath.Join(in.ProjectDir, ".claude", "logs", "CAUSAL_LOG.jsonl")
		}
	}
	retention := h.Retention
	if retention == 0 {
		retention = lookupIntEnv("CAUSAL_LOG_RETENTION_RUNS", 50)
	}
	cap := h.Cap
	if cap == 0 {
		cap = lookupIntEnv("CAUSAL_LOG_MAX_EVENTS", 2000)
	}
	runID := resolveRunID(in)
	log, err := causal.Open(logPath, cap, runID)
	if err != nil {
		return fmt.Errorf("causal_log_finalize: open: %w", err)
	}

	var firstErr error
	if err := h.emitPipelineEnd(log, in); err != nil {
		firstErr = fmt.Errorf("causal_log_finalize: emit: %w", err)
	}
	if err := log.Archive(retention); err != nil && firstErr == nil {
		firstErr = fmt.Errorf("causal_log_finalize: archive: %w", err)
	}
	return firstErr
}

// emitPipelineEnd writes the pipeline_end event with the same context
// shape the bash emit_event built. Detail mirrors "exit_code=<n>", verdict
// is a structured object with status / total turns / total time so
// dashboard parsers don't have to string-parse the detail field.
func (h *CausalLogFinalize) emitPipelineEnd(log *causal.Log, in *Input) error {
	status := "success"
	if in.ExitCode != 0 {
		status = "failed"
	}
	totalTurns := lookupIntEnv("TOTAL_TURNS", 0)
	totalTime := lookupIntEnv("TOTAL_TIME", 0)
	verdict, err := json.Marshal(map[string]any{
		"status":      status,
		"total_turns": totalTurns,
		"total_time":  totalTime,
		"exit_code":   in.ExitCode,
		"disposition": in.Disposition,
	})
	if err != nil {
		return err
	}
	var causedBy []string
	if id, ok := os.LookupEnv("_PIPELINE_START_EVT"); ok && id != "" {
		causedBy = []string{id}
	}
	_, err = log.Emit(causal.EmitInput{
		Stage:     "pipeline",
		Type:      "pipeline_end",
		Detail:    "exit_code=" + strconv.Itoa(in.ExitCode),
		Milestone: in.Milestone,
		CausedBy:  causedBy,
		Verdict:   verdict,
	})
	return err
}

// causalEnabled returns true unless CAUSAL_LOG_ENABLED is explicitly set
// to "false" (matching the bash default).
func causalEnabled() bool {
	raw, ok := os.LookupEnv("CAUSAL_LOG_ENABLED")
	if !ok {
		return true
	}
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "false", "0", "no", "off":
		return false
	}
	return true
}

// resolveRunID prefers Input.Result.RunID, then the RUN_ID env var, then
// a fallback derived from the timestamp.
func resolveRunID(in *Input) string {
	if in.Result != nil && in.Result.RunID != "" {
		return in.Result.RunID
	}
	if id, ok := os.LookupEnv("RUN_ID"); ok && id != "" {
		return id
	}
	if in.Timestamp != "" {
		return "run_" + in.Timestamp
	}
	return "run_unknown"
}
