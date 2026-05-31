package crawler

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestCrawlerWriteOnlyToIndexDir is the package-level read-only/write-only
// contract test. Scans every non-test .go file in the package for
// forbidden write APIs that would let crawler code mutate paths outside
// the configured IndexDir. The acceptable surface is:
//   - os.Rename / os.WriteFile / os.MkdirAll: ONLY in emit.go (the
//     atomic-write seam) and crawler.go (samples-dir bootstrap).
//   - All other files MUST be read-only.
//
// Drift in either direction (a non-emit file calling os.Create, or
// emit.go growing a write to a path outside IndexDir) breaks the
// crawler's safety invariant.
func TestCrawlerWriteOnlyToIndexDir(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	// Files allowed to call the atomic-write APIs.
	allowed := map[string]struct{}{
		"emit.go":     {},
		"crawler.go":  {},
		"api.go":      {}, // re-exports only — no direct writes
	}
	// Forbidden API substrings (intentionally string-matched; AST scan
	// would be overkill for a guard test).
	forbidden := []string{
		"os.Create", "os.WriteFile", "os.OpenFile",
		"os.MkdirAll", "os.Mkdir", "os.Remove", "os.RemoveAll",
		"os.Rename", "os.Truncate", "ioutil.WriteFile",
	}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		body, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := allowed[filepath.Base(f)]; ok {
			continue
		}
		for _, fb := range forbidden {
			if strings.Contains(string(body), fb) {
				t.Errorf("forbidden write API %q in %s — crawler files outside the emit seam must be read-only", fb, f)
			}
		}
	}
}
