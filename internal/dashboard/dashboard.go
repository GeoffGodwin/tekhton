// dashboard.go — lifecycle entry points (Init, SyncStaticFiles, Cleanup,
// Enabled). Ports lib/dashboard.sh:29-120 byte-for-byte equivalently.

package dashboard

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// Enabled mirrors bash is_dashboard_enabled — returns true unless the
// caller passes "false" explicitly. The bash form reads
// `${DASHBOARD_ENABLED:-true}` so the default is on.
func Enabled(enabledStr string) bool {
	return enabledStr != "false"
}

// Init creates <projectDir>/<dashDir>/data/ with the 10 seed data files
// the static HTML expects to <script>-load on first paint. Equivalent to
// bash init_dashboard().
//
// dashDir is relative to projectDir (default ".claude/dashboard").
// templatesDir is the source for static files (TEKHTON_HOME/templates/
// watchtower); when empty the static-file copy step is skipped, matching
// bash _copy_static_files's behavior when $TEKHTON_HOME points to a tree
// without templates/.
func Init(projectDir, dashDir, templatesDir string) error {
	if projectDir == "" {
		return fmt.Errorf("dashboard.Init: empty projectDir")
	}
	if dashDir == "" {
		dashDir = ".claude/dashboard"
	}
	absDash := filepath.Join(projectDir, dashDir)
	if err := ensureDataDir(absDash); err != nil {
		return err
	}
	return copyStaticFiles(absDash, templatesDir)
}

// SyncStaticFiles re-copies the static UI files into an existing dashboard
// dir on every startup. No-op if the dashboard directory does not yet
// exist (matches bash sync_dashboard_static_files exactly).
func SyncStaticFiles(projectDir, dashDir, templatesDir string) error {
	if dashDir == "" {
		dashDir = ".claude/dashboard"
	}
	absDash := filepath.Join(projectDir, dashDir)
	if _, err := os.Stat(absDash); os.IsNotExist(err) {
		return nil
	}
	if err := copyStaticFiles(absDash, templatesDir); err != nil {
		return err
	}
	// Bash form (commit b3476d4) re-creates data/ on sync to defend
	// against gitignore + clean wiping the seed files.
	return ensureDataDir(absDash)
}

// Cleanup removes the entire dashboard directory tree. Idempotent.
func Cleanup(projectDir, dashDir string) error {
	if dashDir == "" {
		dashDir = ".claude/dashboard"
	}
	absDash := filepath.Join(projectDir, dashDir)
	if _, err := os.Stat(absDash); os.IsNotExist(err) {
		return nil
	}
	return os.RemoveAll(absDash)
}

// ensureDataDir creates the data/ subdir and seeds the 10 empty JS data
// files so the static HTML doesn't 404 on its <script> tags. Mirrors bash
// _ensure_dashboard_data_dir line-for-line (same seed JSON literals).
func ensureDataDir(absDash string) error {
	dataDir := filepath.Join(absDash, "data")
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return fmt.Errorf("ensureDataDir: %w", err)
	}
	for _, s := range seedFiles {
		path := filepath.Join(dataDir, s.name)
		if _, err := os.Stat(path); err == nil {
			continue
		}
		if err := WriteJSRaw(path, s.varname, []byte(s.seed), nil); err != nil {
			return fmt.Errorf("ensureDataDir: seed %s: %w", s.name, err)
		}
	}
	return nil
}

// seedFiles is the list of empty JS data files Init plants so the browser
// never sees a 404 on first paint. Identical literal payloads to bash
// _ensure_dashboard_data_dir.
var seedFiles = []struct {
	name    string
	varname string
	seed    string
}{
	{"run_state.js", "TK_RUN_STATE", `{"pipeline_status":"initializing","stages":{}}`},
	{"timeline.js", "TK_TIMELINE", `[]`},
	{"milestones.js", "TK_MILESTONES", `[]`},
	{"security.js", "TK_SECURITY", `{"findings":[]}`},
	{"reports.js", "TK_REPORTS", `{}`},
	{"metrics.js", "TK_METRICS", `{"runs":[]}`},
	{"health.js", "TK_HEALTH", `{"available":false}`},
	{"diagnosis.js", "TK_DIAGNOSIS", `{"available":false}`},
	{"inbox.js", "TK_INBOX", `{"items":[]}`},
	{"notes.js", "TK_NOTES", `[]`},
}

// copyStaticFiles copies index.html / style.css / app.js from
// templatesDir into absDash. Idempotent; no-op when templatesDir is empty
// or missing (bash form returns 0 silently on missing src_dir).
func copyStaticFiles(absDash, templatesDir string) error {
	if templatesDir == "" {
		return nil
	}
	if _, err := os.Stat(templatesDir); os.IsNotExist(err) {
		return nil
	}
	for _, name := range []string{"index.html", "style.css", "app.js"} {
		src := filepath.Join(templatesDir, name)
		dst := filepath.Join(absDash, name)
		f, err := os.Open(src)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return fmt.Errorf("copyStaticFiles open %s: %w", src, err)
		}
		out, err := os.Create(dst)
		if err != nil {
			_ = f.Close()
			return fmt.Errorf("copyStaticFiles create %s: %w", dst, err)
		}
		if _, err := io.Copy(out, f); err != nil {
			_ = f.Close()
			_ = out.Close()
			return fmt.Errorf("copyStaticFiles copy %s: %w", dst, err)
		}
		_ = f.Close()
		_ = out.Close()
	}
	return nil
}

// jsonEscape mirrors lib/causality.sh:_json_escape — backslash, double-
// quote, \n, \r, \t escaped; nothing else. Same semantics as
// proto.writeQuoted but stand-alone so the package doesn't dual-source
// the escape table.
func jsonEscape(s string) string {
	// Use stdlib json.Marshal of the wrapping string — its escape table is
	// a superset of bash's, but for the printable ASCII the bash writer
	// produces in practice they match. The parity gate exercises every
	// real-world value.
	b, err := json.Marshal(s)
	if err != nil {
		return s
	}
	// Strip outer quotes.
	if len(b) >= 2 {
		return string(b[1 : len(b)-1])
	}
	return s
}
