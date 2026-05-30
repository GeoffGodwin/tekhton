// emit_security.go — security.js emit. m33.1 ported the bash emitter
// (lib/dashboard_emitters.sh:emit_dashboard_security); m33.2 moved the
// per-line parser logic into parse_security.go behind the StatusReader.

package dashboard

import (
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EmitSecurity reads SECURITY_REPORT.md (path from env), extracts findings
// via the StatusReader, and writes data/security.js.
func (e *Emitter) EmitSecurity() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	payload, err := e.statusReader().ParseSecurity(e.SecurityReportFile)
	if err != nil {
		return err
	}
	return WriteJSFile(filepath.Join(e.DashDir, "data", "security.js"),
		proto.DashboardVarSecurity, &payload, e.nowFn())
}
