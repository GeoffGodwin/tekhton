// emit_timeline.go — timeline.js emit. Ports
// lib/dashboard_emitters.sh:_regenerate_timeline_js.

package dashboard

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EmitTimeline regenerates data/timeline.js from the causal log. Applies
// the verbosity filter and caps at MaxTimelineEvents. Bash writes a JS
// scaffold with literal indented event lines; the Go form writes a JSON
// array (with the same wrapping JS scaffold) so the parity gate compares
// at the JSON-equivalence level. The browser parses either form
// indistinguishably; the parity gate normalizes whitespace before diff.
func (e *Emitter) EmitTimeline() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	if e.CausalLogFile == "" {
		return nil
	}
	if _, err := os.Stat(e.CausalLogFile); os.IsNotExist(err) {
		return nil
	}
	events, err := e.readTimelineEvents()
	if err != nil {
		return fmt.Errorf("EmitTimeline: %w", err)
	}
	payload := proto.DashboardTimelineV1{Events: events}
	return WriteJSFile(filepath.Join(e.DashDir, "data", "timeline.js"),
		proto.DashboardVarTimeline, payload, e.nowFn())
}

// readTimelineEvents scans the causal log, applies the verbosity filter,
// and returns the trailing window of MaxTimelineEvents passing events.
// Each element is the raw JSON line, preserved byte-for-byte.
func (e *Emitter) readTimelineEvents() ([]json.RawMessage, error) {
	f, err := os.Open(e.CausalLogFile)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()

	keep := timelinePassFn(e.Verbosity)
	cap := e.MaxTimelineEvents
	if cap <= 0 {
		cap = 500
	}

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	var window [][]byte
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		if !keep(line) {
			continue
		}
		cp := append([]byte(nil), line...)
		window = append(window, cp)
		if len(window) > cap {
			window = window[len(window)-cap:]
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	out := make([]json.RawMessage, len(window))
	for i, line := range window {
		out[i] = line
	}
	return out, nil
}

// timelinePassFn returns the per-line filter for the given verbosity.
// Matches the bash case-statement substrings (grep patterns).
func timelinePassFn(verbosity string) func(line []byte) bool {
	switch verbosity {
	case "minimal":
		return func(line []byte) bool {
			s := string(line)
			return strings.Contains(s, `"type":"stage_end"`) ||
				strings.Contains(s, `"type":"verdict"`)
		}
	case "verbose":
		return func(_ []byte) bool { return true }
	case "normal", "":
		return func(line []byte) bool {
			s := string(line)
			return strings.Contains(s, `"type":"stage_`) ||
				strings.Contains(s, `"type":"verdict"`) ||
				strings.Contains(s, `"type":"finding"`) ||
				strings.Contains(s, `"type":"build_gate"`) ||
				strings.Contains(s, `"type":"pipeline_`) ||
				strings.Contains(s, `"type":"milestone_`)
		}
	default:
		return func(_ []byte) bool { return true }
	}
}
