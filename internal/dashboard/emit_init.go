// emit_init.go — init.js emit. Ports
// lib/dashboard_emitters.sh:emit_dashboard_init.

package dashboard

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EmitInit extracts metadata from the INIT_REPORT.md HTML comment block
// and writes data/init.js. No-op when the report file is absent.
func (e *Emitter) EmitInit() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	if _, err := os.Stat(e.InitReportFile); os.IsNotExist(err) {
		return nil
	}
	payload := parseInitReport(e.InitReportFile)
	return WriteJSFile(filepath.Join(e.DashDir, "data", "init.js"),
		proto.DashboardVarInit, &payload, e.nowFn())
}

func parseInitReport(path string) proto.DashboardInitV1 {
	out := proto.DashboardInitV1{Available: true}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer func() { _ = f.Close() }()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	inMeta := false
	for scanner.Scan() {
		line := scanner.Text()
		switch line {
		case "<!-- init-report-meta":
			inMeta = true
			continue
		case "-->":
			inMeta = false
			continue
		}
		if !inMeta {
			continue
		}
		switch {
		case strings.HasPrefix(line, "timestamp:"):
			out.Timestamp = strings.TrimPrefix(line, "timestamp: ")
		case strings.HasPrefix(line, "project:"):
			out.Project = strings.TrimPrefix(line, "project: ")
		case strings.HasPrefix(line, "file_count:"):
			out.FileCount = strings.TrimPrefix(line, "file_count: ")
		case strings.HasPrefix(line, "project_type:"):
			out.ProjectType = strings.TrimPrefix(line, "project_type: ")
		}
	}
	return out
}
