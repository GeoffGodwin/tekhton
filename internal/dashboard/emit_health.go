// emit_health.go — health.js emit. Ports
// lib/dashboard_emitters.sh:emit_dashboard_health.

package dashboard

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EmitHealth reads HEALTH_BASELINE.json verbatim (it's already valid
// JSON) and wraps it in the health.js scaffold. When no baseline exists,
// writes `{"available":false}` and returns.
func (e *Emitter) EmitHealth() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	out := filepath.Join(e.DashDir, "data", "health.js")
	data, err := os.ReadFile(e.HealthBaselineFile)
	if err != nil {
		return WriteJSFile(out, proto.DashboardVarHealth,
			&proto.DashboardHealthV1{Available: false}, e.nowFn())
	}
	belt := deriveHealthBelt(data)
	payload := proto.DashboardHealthV1{
		Available: true,
		Belt:      belt,
		Data:      json.RawMessage(data),
	}
	return WriteJSFile(out, proto.DashboardVarHealth, &payload, e.nowFn())
}

// deriveHealthBelt parses `composite` from the baseline JSON and maps it
// to a belt label using the standard thresholds. Returns "" when the
// field is missing or unparseable.
func deriveHealthBelt(data []byte) string {
	var doc struct {
		Composite any `json:"composite"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return ""
	}
	var score int
	switch v := doc.Composite.(type) {
	case float64:
		score = int(v)
	case int:
		score = v
	case string:
		n, err := strconv.Atoi(v)
		if err != nil {
			return ""
		}
		score = n
	default:
		return ""
	}
	return beltForScore(score)
}

// beltForScore mirrors lib/health.sh::get_health_belt.
func beltForScore(score int) string {
	switch {
	case score >= 90:
		return "Black"
	case score >= 80:
		return "Brown"
	case score >= 70:
		return "Purple"
	case score >= 60:
		return "Blue"
	case score >= 50:
		return "Green"
	case score >= 40:
		return "Orange"
	case score >= 30:
		return "Yellow"
	default:
		return "White"
	}
}
