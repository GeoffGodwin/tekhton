// emit_metrics.go — metrics.js emit. Ports
// lib/dashboard_emitters.sh:emit_dashboard_metrics +
// lib/dashboard_parsers_runs.sh:_parse_run_summaries (JSONL-first path).

package dashboard

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EmitMetrics reads metrics.jsonl (primary) or RUN_SUMMARY_*.json files
// (fallback) and writes data/metrics.js.
func (e *Emitter) EmitMetrics() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	depth := e.HistoryDepth
	if depth <= 0 {
		depth = 50
	}
	runs := e.readRunSummaries(depth)
	payload := proto.DashboardMetricsV1{Runs: runs}
	return WriteJSFile(filepath.Join(e.DashDir, "data", "metrics.js"),
		proto.DashboardVarMetrics, &payload, e.nowFn())
}

// readRunSummaries returns up to depth most-recent runs. Prefers
// metrics.jsonl (one record per line); falls back to glob of
// RUN_SUMMARY_*.json files in LogDir.
func (e *Emitter) readRunSummaries(depth int) []proto.DashboardRunSummary {
	jsonl := filepath.Join(e.LogDir, "metrics.jsonl")
	if rows := readMetricsJSONL(jsonl, depth); len(rows) > 0 {
		return rows
	}
	return readRunSummaryFiles(e.LogDir, depth)
}

func readMetricsJSONL(path string, depth int) []proto.DashboardRunSummary {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer func() { _ = f.Close() }()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	var window []proto.DashboardRunSummary
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var rec proto.DashboardRunSummary
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			continue
		}
		window = append(window, rec)
		if len(window) > depth {
			window = window[len(window)-depth:]
		}
	}
	return window
}

func readRunSummaryFiles(dir string, depth int) []proto.DashboardRunSummary {
	matches, err := filepath.Glob(filepath.Join(dir, "RUN_SUMMARY_*.json"))
	if err != nil || len(matches) == 0 {
		return nil
	}
	sort.Sort(sort.Reverse(sort.StringSlice(matches)))
	if len(matches) > depth {
		matches = matches[:depth]
	}
	var out []proto.DashboardRunSummary
	for i := len(matches) - 1; i >= 0; i-- {
		data, err := os.ReadFile(matches[i])
		if err != nil {
			continue
		}
		var rec proto.DashboardRunSummary
		if err := json.Unmarshal(data, &rec); err != nil {
			continue
		}
		out = append(out, rec)
	}
	return out
}
