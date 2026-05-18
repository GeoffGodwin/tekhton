package finalize

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// EmitTimingReport is the Go body of _hook_emit_timing_report. The bash
// version (lib/timing.sh:102) read `_PHASE_TIMINGS` and `_STAGE_DURATION`
// bash associative arrays populated during the bash pipeline run, then
// wrote TIMING_REPORT.md to LOG_DIR.
//
// Under the Go orchestrator path, the bash globals are not populated, so
// the Go port reads phase timing data from an optional sidecar file
// (PHASE_TIMINGS.json under LOG_DIR) that the per-attempt scheduler can
// produce. When neither the env var nor the sidecar carries data, the
// hook returns nil — matching the bash `return 0 if ${#_PHASE_TIMINGS[@]} -eq 0`
// guard line-for-line.
type EmitTimingReport struct {
	// Path overrides the default TIMING_REPORT.md location.
	Path string

	// PhasesPath overrides the default phase-timings sidecar location.
	PhasesPath string
}

// Name implements Hook.
func (h *EmitTimingReport) Name() string { return "_hook_emit_timing_report" }

// phaseTiming pairs a phase key with its duration (seconds). Used as the
// sort element for the descending-by-duration table order.
type phaseTiming struct {
	Name     string
	Duration int
}

// phaseTimingsSidecar mirrors the JSON shape an optional sidecar file would
// hold. Phases is a map of phase-key → seconds. Total / AgentCalls /
// MaxCalls are header summary fields. None of these are required —
// missing values default to zero.
type phaseTimingsSidecar struct {
	Phases     map[string]int `json:"phases,omitempty"`
	Total      int            `json:"total_seconds,omitempty"`
	AgentCalls int            `json:"agent_calls,omitempty"`
	MaxCalls   int            `json:"max_agent_calls,omitempty"`
	Timestamp  string         `json:"timestamp,omitempty"`
}

// Run writes TIMING_REPORT.md if any phase data is available; otherwise
// no-ops.
func (h *EmitTimingReport) Run(_ context.Context, in *Input) error {
	logDir := in.LogDir
	if logDir == "" {
		logDir = filepath.Join(in.ProjectDir, ".claude", "logs")
	}
	sidecar, ok := h.loadPhases(logDir)
	if !ok {
		// Bash behavior: skip emission when no phases were recorded.
		return nil
	}
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return fmt.Errorf("emit_timing_report: mkdir log dir: %w", err)
	}
	path := h.Path
	if path == "" {
		path = filepath.Join(logDir, "TIMING_REPORT.md")
	}

	body := h.render(in, sidecar)
	if err := writeFileAtomic(path, []byte(body)); err != nil {
		return fmt.Errorf("emit_timing_report: write: %w", err)
	}
	return nil
}

// loadPhases reads PHASE_TIMINGS.json from the sidecar location. Returns
// (data, true) on success; (zero, false) when no data is available so the
// caller can short-circuit. Also folds in RunResultV1.ElapsedSecs as the
// header total when the sidecar is absent but the run result is non-zero.
func (h *EmitTimingReport) loadPhases(logDir string) (phaseTimingsSidecar, bool) {
	path := h.PhasesPath
	if path == "" {
		path = filepath.Join(logDir, "PHASE_TIMINGS.json")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return phaseTimingsSidecar{}, false
	}
	var sc phaseTimingsSidecar
	if err := json.Unmarshal(data, &sc); err != nil {
		return phaseTimingsSidecar{}, false
	}
	if len(sc.Phases) == 0 {
		return phaseTimingsSidecar{}, false
	}
	return sc, true
}

// render returns the markdown body. Format matches the bash heredoc at
// lib/timing.sh:245 — header line, note block, table, footer summary.
func (h *EmitTimingReport) render(in *Input, sc phaseTimingsSidecar) string {
	total := sc.Total
	if total == 0 {
		for _, v := range sc.Phases {
			total += v
		}
	}
	if total == 0 && in.Result != nil && in.Result.ElapsedSecs > 0 {
		total = int(in.Result.ElapsedSecs)
	}

	phases := make([]phaseTiming, 0, len(sc.Phases))
	for k, v := range sc.Phases {
		if v <= 0 {
			continue
		}
		phases = append(phases, phaseTiming{Name: k, Duration: v})
	}
	sort.Slice(phases, func(i, j int) bool {
		if phases[i].Duration != phases[j].Duration {
			return phases[i].Duration > phases[j].Duration
		}
		return phases[i].Name < phases[j].Name
	})

	ts := sc.Timestamp
	if ts == "" {
		ts = in.Timestamp
	}
	if ts == "" {
		ts = time.Now().UTC().Format("20060102_150405")
	}

	agentCalls := sc.AgentCalls
	if agentCalls == 0 && in.Result != nil {
		agentCalls = in.Result.AgentCalls
	}
	maxCalls := sc.MaxCalls
	if maxCalls == 0 {
		maxCalls = lookupIntEnv("MAX_AUTONOMOUS_AGENT_CALLS", 20)
	}

	var b strings.Builder
	fmt.Fprintf(&b, "## Timing Report — run_%s\n\n", ts)
	b.WriteString("> **Note:** Some phases are nested (e.g., `coder_prompt` runs inside\n")
	b.WriteString("> `context_assembly`). Percentage totals may slightly exceed the expected\n")
	b.WriteString("> sum due to this overlap. Individual phase durations are accurate.\n\n")
	b.WriteString("| Phase | Duration | % of Total |\n")
	b.WriteString("|-------|----------|-----------|\n")
	for _, p := range phases {
		pct := "<1"
		if total > 0 && p.Duration > 0 {
			n := (p.Duration * 100) / total
			if n == 0 {
				pct = "<1"
			} else {
				pct = fmt.Sprintf("%d", n)
			}
		}
		fmt.Fprintf(&b, "| %s | %s | %s%% |\n", phaseDisplayName(p.Name), formatDurationHuman(p.Duration), pct)
	}
	fmt.Fprintf(&b, "\nTotal wall time: %s\n", formatDurationHuman(total))
	fmt.Fprintf(&b, "Agent calls: %d (of %d max)\n", agentCalls, maxCalls)
	return b.String()
}

// phaseDisplayName mirrors the bash _phase_display_name lookup table.
func phaseDisplayName(key string) string {
	switch key {
	case "startup":
		return "Startup"
	case "config_load":
		return "Config load + detection"
	case "indexer":
		return "Indexer (repo map)"
	case "scout_prompt":
		return "Scout (prompt assembly)"
	case "scout_agent":
		return "Scout (agent)"
	case "coder_prompt":
		return "Coder (prompt assembly)"
	case "coder_agent":
		return "Coder (agent)"
	case "coder_continuation":
		return "Coder (continuation)"
	case "reviewer_prompt":
		return "Reviewer (prompt assembly)"
	case "reviewer_agent":
		return "Reviewer (agent)"
	case "rework_agent":
		return "Rework (agent)"
	case "tester_prompt":
		return "Tester (prompt assembly)"
	case "tester_agent":
		return "Tester (agent)"
	case "tester_continuation":
		return "Tester (continuation)"
	case "build_gate":
		return "Build gate"
	case "build_gate_analyze":
		return "Build gate (analyze)"
	case "build_gate_compile":
		return "Build gate (compile)"
	case "build_gate_constraints":
		return "Build gate (constraints)"
	case "build_gate_ui_test":
		return "Build gate (UI test)"
	case "build_gate_ui_validate":
		return "Build gate (UI validate)"
	case "intake_agent":
		return "Intake (agent)"
	case "security_agent":
		return "Security (agent)"
	case "architect_agent":
		return "Architect (agent)"
	case "context_assembly":
		return "Context assembly"
	case "finalization":
		return "Finalization"
	case "preflight_fix":
		return "Preflight fix"
	default:
		return key
	}
}

// formatDurationHuman mirrors the bash _format_duration_human helper in
// lib/common.sh: <60s "Ns", <3600s "Nm Ms", else "Nh Mm".
func formatDurationHuman(seconds int) string {
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	}
	if seconds < 3600 {
		m := seconds / 60
		s := seconds % 60
		if s == 0 {
			return fmt.Sprintf("%dm", m)
		}
		return fmt.Sprintf("%dm %ds", m, s)
	}
	h := seconds / 3600
	m := (seconds % 3600) / 60
	if m == 0 {
		return fmt.Sprintf("%dh", h)
	}
	return fmt.Sprintf("%dh %dm", h, m)
}
