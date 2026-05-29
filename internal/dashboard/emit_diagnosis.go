// emit_diagnosis.go — diagnosis.js emit. The bash form is owned by
// _hook_failure_context (lib/finalize_dashboard_hooks.sh:128) which calls
// the legacy emit_dashboard_diagnosis function. m33.1 ships a stub that
// preserves the on-disk shape; m33.2 (or a follow-up) will plug in the
// LAST_FAILURE_CONTEXT.json parser.

package dashboard

import (
	"encoding/json"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EmitDiagnosis writes data/diagnosis.js. When LAST_FAILURE_CONTEXT.json
// exists in .claude/, the available flag is true and the
// classification/stage/summary fields are populated; otherwise the file
// holds `{"available":false}`.
func (e *Emitter) EmitDiagnosis() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	out := filepath.Join(e.DashDir, "data", "diagnosis.js")
	ctxPath := filepath.Join(e.ProjectDir, ".claude", "LAST_FAILURE_CONTEXT.json")
	data, err := os.ReadFile(ctxPath)
	if err != nil {
		return WriteJSFile(out, proto.DashboardVarDiagnosis,
			&proto.DashboardDiagnosisV1{Available: false}, e.nowFn())
	}
	payload := proto.DashboardDiagnosisV1{Available: true}
	var doc struct {
		Classification string `json:"classification"`
		Stage          string `json:"stage"`
		Summary        string `json:"summary"`
	}
	if err := json.Unmarshal(data, &doc); err == nil {
		payload.Classification = doc.Classification
		payload.Stage = doc.Stage
		payload.Summary = doc.Summary
	}
	return WriteJSFile(out, proto.DashboardVarDiagnosis, &payload, e.nowFn())
}
