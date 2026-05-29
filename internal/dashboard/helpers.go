// helpers.go — small per-emitter helpers shared across emit_*.go files.

package dashboard

import (
	"errors"
	"os"
	"path/filepath"
	"time"
)

// errEmptyTeamID is returned by EmitTeamState when no team id is passed.
// Mirrors lib/dashboard.sh:302 `warn ... return 1`.
var errEmptyTeamID = errors.New("dashboard.EmitTeamState: team_id required")

// dataDirExists is the same gate bash uses (`[[ ! -d "${dash_dir}/data" ]] && return 0`)
// to no-op the emitter when Init has not been called yet.
func (e *Emitter) dataDirExists() bool {
	_, err := os.Stat(filepath.Join(e.DashDir, "data"))
	return err == nil
}

// nowFn returns the Emitter's time source or the package default. Kept as
// a method so tests can override e.Now.
func (e *Emitter) nowFn() jsFileTimeFunc {
	if e.Now != nil {
		return e.Now
	}
	return time.Now
}

func defaultIfEmpty(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}
