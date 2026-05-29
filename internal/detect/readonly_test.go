package detect

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestReadOnlyContract enforces the package-level invariant: detectors
// must not write to the filesystem. The CLI surface
// (cmd/tekhton/detect.go) is the only place os.Stdout writes are allowed
// — package-internal code stays read-only so future m29.2 detectors land
// against a fixed contract.
//
// The test grep-scans every non-test .go file in the package for the
// forbidden write APIs. Adding a new write needs an intentional, reviewed
// edit to this test alongside the change.
func TestReadOnlyContract(t *testing.T) {
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	// Patterns require a trailing `(` so callers can document the
	// forbidden APIs in comments without tripping the check. A real
	// invocation is `os.Create(...)`; a doc reference is `os.Create`.
	forbidden := []struct {
		name    string
		pattern string
	}{
		{"os.Create", `\bos\.Create\(`},
		{"os.WriteFile", `\bos\.WriteFile\(`},
		{"ioutil.WriteFile", `\bioutil\.WriteFile\(`},
		{"os.OpenFile with O_WRONLY", `os\.OpenFile\([^)]*O_WRONLY`},
		{"os.OpenFile with O_CREATE", `os\.OpenFile\([^)]*O_CREATE`},
		{"os.Remove", `\bos\.Remove\(`},
		{"os.RemoveAll", `\bos\.RemoveAll\(`},
		{"os.MkdirAll", `\bos\.MkdirAll\(`},
		{"os.Mkdir", `\bos\.Mkdir\(`},
		{"os.Rename", `\bos\.Rename\(`},
	}
	files, err := filepath.Glob(filepath.Join(wd, "*.go"))
	if err != nil {
		t.Fatalf("Glob: %v", err)
	}
	if len(files) == 0 {
		t.Fatalf("no .go files found in %s", wd)
	}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		body, err := os.ReadFile(f) //nolint:gosec // intentional read of files in this package
		if err != nil {
			t.Fatalf("read %s: %v", f, err)
		}
		text := string(body)
		for _, pat := range forbidden {
			rx := regexp.MustCompile(pat.pattern)
			if rx.MatchString(text) {
				t.Errorf("read-only contract violation: %s contains %s (pattern %s)",
					filepath.Base(f), pat.name, pat.pattern)
			}
		}
	}
}
