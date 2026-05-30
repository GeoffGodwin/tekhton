// parse.go — StatusReader type. m33.2 ports the bash dashboard parsers
// (lib/dashboard_parsers.sh, lib/dashboard_parsers_runs.sh,
// lib/dashboard_parsers_runs_files.sh) into the dashboard package.
//
// The StatusReader is the READ side of the dashboard data layer: it turns
// stage report files (markdown) and metrics records (JSONL, JSON) into the
// typed dashboard.v1 payloads the emitters write. All methods are read-only
// on disk and pure on input — they take a path and return a typed struct +
// error. No side effects beyond opening the file for read.
//
// The Emitter holds one StatusReader (constructed by NewStatusReader) and
// dispatches the per-payload Parse<Kind> calls through it.

package dashboard

// StatusReader is the parser dispatcher for stage report markdown files and
// metrics records. Construct one per emit cycle; methods are safe to call
// concurrently with one another but each individual call is single-threaded
// (one os.Open + scan).
type StatusReader struct {
	// ProjectDir is the absolute path of the project root. Used only when a
	// caller passes a relative file path; the Parse* methods themselves do
	// not resolve relative-to-projectdir, callers do.
	ProjectDir string
	// LogDir is the absolute path of the project's logs directory (where
	// metrics.jsonl and the RUN_SUMMARY_*.json fallback files live). Used
	// by ParseRunSummaries.
	LogDir string
}

// NewStatusReader returns a populated StatusReader using the dirs from the
// supplied Emitter. The Emitter is the canonical source of truth for both
// dirs — keeping the relationship one-way avoids a second copy of the
// env-resolution logic.
func NewStatusReader(e *Emitter) *StatusReader {
	if e == nil {
		return &StatusReader{}
	}
	return &StatusReader{ProjectDir: e.ProjectDir, LogDir: e.LogDir}
}
