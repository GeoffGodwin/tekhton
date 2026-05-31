package crawler

import (
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// recordingWriter is a Writer fake used to assert (a) atomic-write
// semantics — every WriteAtomic call resolves to a path inside the
// configured IndexDir prefix; (b) emission ordering.
type recordingWriter struct {
	mu        sync.Mutex
	indexDir  string
	writes    []recordedWrite
	samples   []recordedSample
	leftovers []string
}

type recordedWrite struct {
	Name string
	Body []byte
}

type recordedSample struct {
	SamplesDir string
	Stored     string
	Body       []byte
}

func newRecordingWriter(indexDir string) *recordingWriter {
	return &recordingWriter{indexDir: indexDir}
}

func (r *recordingWriter) WriteAtomic(name string, body []byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !strings.HasPrefix(name, r.indexDir) {
		return &writeOutsideIndexErr{path: name, prefix: r.indexDir}
	}
	r.writes = append(r.writes, recordedWrite{Name: name, Body: append([]byte(nil), body...)})
	return nil
}

func (r *recordingWriter) WriteSampleFile(samplesDir, storedName string, body []byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !strings.HasPrefix(samplesDir, r.indexDir) {
		return &writeOutsideIndexErr{path: samplesDir, prefix: r.indexDir}
	}
	r.samples = append(r.samples, recordedSample{
		SamplesDir: samplesDir, Stored: storedName, Body: append([]byte(nil), body...),
	})
	return nil
}

func (r *recordingWriter) RemoveSampleLeftovers(samplesDir string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.leftovers = append(r.leftovers, samplesDir)
	return nil
}

func (r *recordingWriter) EnsureSamplesDir(string) error { return nil }

type writeOutsideIndexErr struct{ path, prefix string }

func (e *writeOutsideIndexErr) Error() string {
	return "crawler test: write outside index dir: " + e.path + " (prefix=" + e.prefix + ")"
}

// TestWriteOnlyToIndexDir is the crawler's load-bearing safety invariant.
// Every WriteAtomic / WriteSampleFile call MUST target a path under the
// configured IndexDir — never the project tree.
func TestWriteOnlyToIndexDir(t *testing.T) {
	indexDir := "/tmp/m30-test-index"
	w := newRecordingWriter(indexDir)
	inv := &Inventory{Entries: []InventoryEntry{{Path: "a.go", Dir: ".", Lines: 1, Size: "tiny"}}}
	if err := emitInventoryJSONL(w, indexDir, inv); err != nil {
		t.Fatal(err)
	}
	if err := emitConfigsJSON(w, indexDir, &ConfigInventory{}); err != nil {
		t.Fatal(err)
	}
	if err := emitTestsJSON(w, indexDir, &TestStructure{}); err != nil {
		t.Fatal(err)
	}
	if err := emitDependenciesJSON(w, indexDir, &DependencyGraph{}); err != nil {
		t.Fatal(err)
	}
	if err := emitMetaJSON(w, indexDir, MetaInputs{ProjectName: "x"}); err != nil {
		t.Fatal(err)
	}
	if err := emitTreeTxt(w, indexDir, "fake\n"); err != nil {
		t.Fatal(err)
	}
	if len(w.writes) != 6 {
		t.Errorf("expected 6 writes, got %d", len(w.writes))
	}
	for _, w := range w.writes {
		if !strings.HasPrefix(w.Name, indexDir+"/") {
			t.Errorf("write outside index dir: %s", w.Name)
		}
	}
}

func TestEmitInventoryJSONLByteShape(t *testing.T) {
	w := newRecordingWriter("/x")
	inv := &Inventory{
		Entries: []InventoryEntry{
			{Path: "a.go", Dir: ".", Lines: 0, Size: "tiny"},
			{Path: "sub/b.go", Dir: "sub", Lines: 100, Size: "small"},
		},
	}
	if err := emitInventoryJSONL(w, "/x", inv); err != nil {
		t.Fatal(err)
	}
	body := string(w.writes[0].Body)
	want := `{"path":"a.go","dir":".","lines":0,"size":"tiny"}` + "\n" +
		`{"path":"sub/b.go","dir":"sub","lines":100,"size":"small"}` + "\n"
	if body != want {
		t.Errorf("inventory.jsonl shape:\n  got  %q\n  want %q", body, want)
	}
}

func TestEmitConfigsJSONEmpty(t *testing.T) {
	w := newRecordingWriter("/x")
	if err := emitConfigsJSON(w, "/x", &ConfigInventory{}); err != nil {
		t.Fatal(err)
	}
	got := string(w.writes[0].Body)
	want := "{\n  \"configs\": [\n  ]\n}\n"
	if got != want {
		t.Errorf("empty configs.json shape:\n  got  %q\n  want %q", got, want)
	}
}

func TestEmitTestsJSONInlineArrays(t *testing.T) {
	// frameworks and coverage MUST be inline (`[]` not `[\n  ]`)
	// for parity with bash.
	w := newRecordingWriter("/x")
	if err := emitTestsJSON(w, "/x", &TestStructure{}); err != nil {
		t.Fatal(err)
	}
	got := string(w.writes[0].Body)
	if !strings.Contains(got, `"frameworks": []`) {
		t.Errorf("frameworks should be inline []: %q", got)
	}
	if !strings.Contains(got, `"coverage": []`) {
		t.Errorf("coverage should be inline []: %q", got)
	}
}

func TestEmitMetaJSONShape(t *testing.T) {
	w := newRecordingWriter("/x")
	m := MetaInputs{
		ProjectName: "demo", ScanDate: "DATE", ScanCommit: "COMMIT",
		FileCount: 7, TotalLines: 100, TreeLines: 5, DocQualityScore: 80,
	}
	if err := emitMetaJSON(w, "/x", m); err != nil {
		t.Fatal(err)
	}
	got := string(w.writes[0].Body)
	want := `{
  "schema_version": 1,
  "project_name": "demo",
  "scan_date": "DATE",
  "scan_commit": "COMMIT",
  "file_count": 7,
  "total_lines": 100,
  "tree_lines": 5,
  "doc_quality_score": 80
}
`
	if got != want {
		t.Errorf("meta.json shape:\n  got  %q\n  want %q", got, want)
	}
}

func TestEmitDependenciesJSONShape(t *testing.T) {
	w := newRecordingWriter("/x")
	g := &DependencyGraph{
		Manifests: []Manifest{{File: "package.json", Manager: "npm", Deps: 2, DevDeps: 1}},
		KeyDependencies: []Dependency{
			{Name: "react", Version: "^18.0.0", Manifest: "package.json"},
		},
	}
	if err := emitDependenciesJSON(w, "/x", g); err != nil {
		t.Fatal(err)
	}
	got := string(w.writes[0].Body)
	if !strings.Contains(got, `{"file":"package.json","manager":"npm","deps":2,"dev_deps":1}`) {
		t.Errorf("manifest line shape drift: %q", got)
	}
	if !strings.Contains(got, `{"name":"react","version":"^18.0.0","manifest":"package.json"}`) {
		t.Errorf("key dep line shape drift: %q", got)
	}
}

func TestJSONEscape(t *testing.T) {
	cases := map[string]string{
		"plain":        "plain",
		`with"quote`:   `with\"quote`,
		"back\\slash":  "back\\\\slash",
		"line1\nline2": "line1\\nline2",
		"a\tb":         "a\\tb",
		"\r":           "\\r",
	}
	for in, want := range cases {
		var b strings.Builder
		jsonEscape(&b, in)
		if b.String() != want {
			t.Errorf("jsonEscape(%q) = %q, want %q", in, b.String(), want)
		}
	}
}

func TestSamplesDirPathPrefix(t *testing.T) {
	// Ensure samples land under <indexDir>/samples/, never elsewhere.
	indexDir := "/index"
	w := newRecordingWriter(indexDir)
	samples := []Sample{{Original: "README.md", Stored: "README.md.txt", Content: "hi", Chars: 2}}
	if err := emitSamples(w, indexDir, samples, 2, 100); err != nil {
		t.Fatal(err)
	}
	if len(w.samples) != 1 {
		t.Fatalf("expected 1 sample write, got %d", len(w.samples))
	}
	want := filepath.Join(indexDir, "samples")
	if w.samples[0].SamplesDir != want {
		t.Errorf("sample dir: got %q want %q", w.samples[0].SamplesDir, want)
	}
}
