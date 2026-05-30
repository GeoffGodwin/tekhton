// emit_metrics.go — metrics.js emit. Ports
// lib/dashboard_emitters.sh:emit_dashboard_metrics. The run-summary parser
// body (metrics.jsonl primary + RUN_SUMMARY_*.json fallback) lives in
// parse_runs.go behind the StatusReader after m33.2.

package dashboard

import (
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EmitMetrics dispatches to the StatusReader (which reads metrics.jsonl or
// the RUN_SUMMARY fallback) and writes data/metrics.js.
func (e *Emitter) EmitMetrics() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	depth := e.HistoryDepth
	if depth <= 0 {
		depth = 50
	}
	runs, err := e.statusReader().ParseRunSummaries("", "", depth)
	if err != nil {
		return err
	}
	payload := proto.DashboardMetricsV1{Runs: runs}
	return WriteJSFile(filepath.Join(e.DashDir, "data", "metrics.js"),
		proto.DashboardVarMetrics, &payload, e.nowFn())
}
