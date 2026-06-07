package test_audit

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDetectStaleSymbolRefs_FixtureFindsMissingSymbol(t *testing.T) {
	ac := &AuditContext{
		TestFiles: []string{"tests/test_foo.py", "tests/test_bar.py"},
	}
	opts := SymbolOptions{
		SymbolMapEnabled: true,
		TestMapFile:      "testdata/stale-sym/test_map.json",
		TagsFile:         "testdata/stale-sym/tags.json",
		SerenaActive:     true,
	}
	got := DetectStaleSymbolRefs(context.Background(), ac, opts)
	if len(got) != 1 {
		t.Fatalf("expected exactly 1 stale-symbol finding (GoneSym), got %d: %v", len(got), got)
	}
	want := "STALE-SYM: tests/test_foo.py references 'GoneSym' not found in any source definition"
	if got[0] != want {
		t.Fatalf("unexpected finding text:\n got:  %q\n want: %q", got[0], want)
	}
}

func TestDetectStaleSymbolRefs_GateDisabled(t *testing.T) {
	ac := &AuditContext{TestFiles: []string{"tests/test_foo.py"}}
	opts := SymbolOptions{
		SymbolMapEnabled: false,
		TestMapFile:      "testdata/stale-sym/test_map.json",
		TagsFile:         "testdata/stale-sym/tags.json",
	}
	got := DetectStaleSymbolRefs(context.Background(), ac, opts)
	if len(got) != 0 {
		t.Fatalf("disabled gate should return empty, got %d", len(got))
	}
}

func TestDetectStaleSymbolRefs_EmptyMapFile(t *testing.T) {
	ac := &AuditContext{TestFiles: []string{"tests/test_foo.py"}}
	opts := SymbolOptions{
		SymbolMapEnabled: true,
		TestMapFile:      "",
	}
	got := DetectStaleSymbolRefs(context.Background(), ac, opts)
	if len(got) != 0 {
		t.Fatalf("empty map file should return empty, got %d", len(got))
	}
}

func TestDetectStaleSymbolRefs_MissingTagsFile(t *testing.T) {
	dir := t.TempDir()
	mapPath := filepath.Join(dir, "test_map.json")
	if err := os.WriteFile(mapPath, []byte(`{"files":{"a":["X"]}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	ac := &AuditContext{TestFiles: []string{"a"}}
	opts := SymbolOptions{
		SymbolMapEnabled: true,
		TestMapFile:      mapPath,
		TagsFile:         filepath.Join(dir, "tags.json"),
	}
	got := DetectStaleSymbolRefs(context.Background(), ac, opts)
	if len(got) != 0 {
		t.Fatalf("missing tags file should return empty, got %d", len(got))
	}
}

func TestDetectStaleSymbolRefs_NoTestFiles(t *testing.T) {
	ac := &AuditContext{}
	opts := SymbolOptions{
		SymbolMapEnabled: true,
		TestMapFile:      "testdata/stale-sym/test_map.json",
		TagsFile:         "testdata/stale-sym/tags.json",
	}
	got := DetectStaleSymbolRefs(context.Background(), ac, opts)
	if len(got) != 0 {
		t.Fatalf("no test files should return empty, got %d", len(got))
	}
}

func TestDetectStaleSymbolRefs_AppendsToOrphanFindings(t *testing.T) {
	// Bash parity: stale-sym findings are appended to _AUDIT_ORPHAN_FINDINGS
	// so the audit prompt's "Shell-Detected Orphans" section captures both.
	ac := &AuditContext{
		TestFiles:      []string{"tests/test_foo.py"},
		OrphanFindings: []string{"ORPHAN: prior finding"},
	}
	opts := SymbolOptions{
		SymbolMapEnabled: true,
		TestMapFile:      "testdata/stale-sym/test_map.json",
		TagsFile:         "testdata/stale-sym/tags.json",
		SerenaActive:     true,
	}
	_ = DetectStaleSymbolRefs(context.Background(), ac, opts)
	hasPrior := false
	hasStale := false
	for _, f := range ac.OrphanFindings {
		if f == "ORPHAN: prior finding" {
			hasPrior = true
		}
		if strings.Contains(f, "STALE-SYM:") {
			hasStale = true
		}
	}
	if !hasPrior || !hasStale {
		t.Fatalf("expected both prior + stale-sym in OrphanFindings, got %v", ac.OrphanFindings)
	}
}
