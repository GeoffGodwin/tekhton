package crawler

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Writer is the seam between the crawler and the filesystem. Production
// code uses fsWriter (os-backed); tests can inject a recording fake to
// assert atomic-write semantics and the write-only-to-IndexDir contract.
type Writer interface {
	WriteAtomic(name string, body []byte) error
	WriteSampleFile(samplesDir, storedName string, body []byte) error
	RemoveSampleLeftovers(samplesDir string) error
	EnsureSamplesDir(samplesDir string) error
}

// fsWriter is the production Writer. Every write is staged in the
// destination directory (so os.Rename is same-filesystem atomic) and
// only renamed once the bytes hit disk. Mirrors the bash mktemp + mv
// pattern in lib/crawler*.sh.
type fsWriter struct{}

func (fsWriter) WriteAtomic(name string, body []byte) error {
	dir := filepath.Dir(name)
	tmp, err := os.CreateTemp(dir, filepath.Base(name)+"_*.tmp")
	if err != nil {
		return fmt.Errorf("crawler: create temp for %s: %w", name, err)
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(body); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return fmt.Errorf("crawler: write temp for %s: %w", name, err)
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("crawler: close temp for %s: %w", name, err)
	}
	if err := os.Rename(tmpPath, name); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("crawler: rename temp to %s: %w", name, err)
	}
	return nil
}

func (fsWriter) WriteSampleFile(samplesDir, storedName string, body []byte) error {
	return os.WriteFile(filepath.Join(samplesDir, storedName), body, 0o644) //nolint:gosec // index artifact
}

func (fsWriter) RemoveSampleLeftovers(samplesDir string) error {
	matches, err := filepath.Glob(filepath.Join(samplesDir, "*.txt"))
	if err != nil {
		return err
	}
	for _, m := range matches {
		if err := os.Remove(m); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

func (fsWriter) EnsureSamplesDir(samplesDir string) error {
	return os.MkdirAll(samplesDir, 0o755)
}

// --- tree.txt -----------------------------------------------------------

// emitTreeTxt writes the directory tree to .claude/index/tree.txt with
// the trailing newline the bash version appended via `printf '\n'`.
func emitTreeTxt(w Writer, indexDir string, treeContent string) error {
	body := treeContent
	// Bash appends a single '\n' regardless of whether the tree text
	// already ends in one; emulating that may produce a double newline
	// for tree-binary output. The bash also produces the double newline
	// in that case, so preserve it.
	body += "\n"
	return w.WriteAtomic(filepath.Join(indexDir, "tree.txt"), []byte(body))
}

// --- inventory.jsonl ---------------------------------------------------

// emitInventoryJSONL writes one JSONL record per file. Field order
// (path, dir, lines, size) and quoting must match bash exactly — every
// downstream consumer reads by key but the parity gate is byte-level.
func emitInventoryJSONL(w Writer, indexDir string, inv *Inventory) error {
	var b strings.Builder
	for _, e := range inv.Entries {
		b.WriteString(`{"path":"`)
		jsonEscape(&b, e.Path)
		b.WriteString(`","dir":"`)
		jsonEscape(&b, e.Dir)
		b.WriteString(`","lines":`)
		b.WriteString(strconv.Itoa(e.Lines))
		b.WriteString(`,"size":"`)
		b.WriteString(e.Size)
		b.WriteString(`"}` + "\n")
	}
	return w.WriteAtomic(filepath.Join(indexDir, "inventory.jsonl"), []byte(b.String()))
}

// --- dependencies.json -------------------------------------------------

// emitDependenciesJSON writes the dependency graph as pretty-printed JSON
// matching the exact bash printf layout: each manifest / key_dependency
// entry indented `\n    `; arrays close on their own `\n  ]` line.
func emitDependenciesJSON(w Writer, indexDir string, g *DependencyGraph) error {
	var b strings.Builder
	b.WriteString(`{` + "\n" + `  "manifests": [`)
	for i, m := range g.Manifests {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString("\n    ")
		b.WriteString(`{"file":"`)
		jsonEscape(&b, m.File)
		b.WriteString(`","manager":"`)
		jsonEscape(&b, m.Manager)
		b.WriteString(`","deps":`)
		b.WriteString(strconv.Itoa(m.Deps))
		b.WriteString(`,"dev_deps":`)
		b.WriteString(strconv.Itoa(m.DevDeps))
		b.WriteString(`}`)
	}
	b.WriteString("\n  ],\n  \"key_dependencies\": [")
	for i, d := range g.KeyDependencies {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString("\n    ")
		b.WriteString(`{"name":"`)
		jsonEscape(&b, d.Name)
		b.WriteString(`","version":"`)
		jsonEscape(&b, d.Version)
		b.WriteString(`","manifest":"`)
		jsonEscape(&b, d.Manifest)
		b.WriteString(`"}`)
	}
	b.WriteString("\n  ]\n}\n")
	return w.WriteAtomic(filepath.Join(indexDir, "dependencies.json"), []byte(b.String()))
}

// --- configs.json ------------------------------------------------------

// emitConfigsJSON writes the config inventory. Matches bash's layout —
// empty configs render as a multi-line `[\n  ]`.
func emitConfigsJSON(w Writer, indexDir string, cfg *ConfigInventory) error {
	var b strings.Builder
	b.WriteString(`{` + "\n" + `  "configs": [`)
	for i, e := range cfg.Entries {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString("\n    ")
		b.WriteString(`{"path":"`)
		jsonEscape(&b, e.Path)
		b.WriteString(`","purpose":"`)
		jsonEscape(&b, e.Purpose)
		b.WriteString(`"}`)
	}
	b.WriteString("\n  ]\n}\n")
	return w.WriteAtomic(filepath.Join(indexDir, "configs.json"), []byte(b.String()))
}

// --- tests.json --------------------------------------------------------

// emitTestsJSON writes the test infrastructure summary. Note the asymmetry
// with the bash version: test_dirs is multi-line (matching dependencies /
// configs), but frameworks and coverage are inline arrays because the
// bash printf chain emits no leading newline between entries.
func emitTestsJSON(w Writer, indexDir string, t *TestStructure) error {
	var b strings.Builder
	b.WriteString(`{` + "\n" + `  "test_dirs": [`)
	for i, d := range t.TestDirs {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString("\n    ")
		b.WriteString(`{"path":"`)
		jsonEscape(&b, d.Path)
		b.WriteString(`","file_count":`)
		b.WriteString(strconv.Itoa(d.FileCount))
		b.WriteString(`}`)
	}
	b.WriteString("\n  ],\n  \"test_file_count\": ")
	b.WriteString(strconv.Itoa(t.TestFileCount))
	b.WriteString(`,` + "\n" + `  "frameworks": [`)
	for i, fw := range t.Frameworks {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('"')
		jsonEscape(&b, fw)
		b.WriteByte('"')
	}
	b.WriteString(`],` + "\n" + `  "coverage": [`)
	for i, c := range t.Coverage {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('"')
		jsonEscape(&b, c)
		b.WriteByte('"')
	}
	b.WriteString("]\n}\n")
	return w.WriteAtomic(filepath.Join(indexDir, "tests.json"), []byte(b.String()))
}

// --- samples/* ---------------------------------------------------------

// emitSamples writes one sample file per entry and a manifest.json
// summary. Calls EnsureSamplesDir and RemoveSampleLeftovers first.
func emitSamples(w Writer, indexDir string, samples []Sample, totalChars, budgetChars int) error {
	samplesDir := filepath.Join(indexDir, "samples")
	if err := w.EnsureSamplesDir(samplesDir); err != nil {
		return err
	}
	if err := w.RemoveSampleLeftovers(samplesDir); err != nil {
		return err
	}
	for _, s := range samples {
		if err := w.WriteSampleFile(samplesDir, s.Stored, []byte(s.Content)); err != nil {
			return err
		}
	}
	// Manifest.
	var b strings.Builder
	b.WriteString(`{` + "\n" + `  "samples": [`)
	for i, s := range samples {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString("\n    ")
		b.WriteString(`{"original":"`)
		jsonEscape(&b, s.Original)
		b.WriteString(`","stored":"`)
		jsonEscape(&b, s.Stored)
		b.WriteString(`","chars":`)
		b.WriteString(strconv.Itoa(s.Chars))
		b.WriteString(`}`)
	}
	b.WriteString("\n  ],\n  \"total_chars\": ")
	b.WriteString(strconv.Itoa(totalChars))
	b.WriteString(`,` + "\n" + `  "budget_chars": `)
	b.WriteString(strconv.Itoa(budgetChars))
	b.WriteString("\n}\n")
	return w.WriteAtomic(filepath.Join(samplesDir, "manifest.json"), []byte(b.String()))
}

// --- meta.json ---------------------------------------------------------

// MetaInputs is the data emitMetaJSON consumes. Centralized so the
// orchestrator can stamp values in one place and the parity test can
// inject deterministic scan_date / scan_commit values.
type MetaInputs struct {
	ProjectName     string
	ScanDate        string
	ScanCommit      string
	FileCount       int
	TotalLines      int
	TreeLines       int
	DocQualityScore int
}

// emitMetaJSON writes scan metadata last so it can read file_count and
// total_lines from the just-written inventory.jsonl. The orchestrator
// enforces ordering by populating MetaInputs from the inventory and the
// tree text BEFORE this is invoked.
func emitMetaJSON(w Writer, indexDir string, m MetaInputs) error {
	var b strings.Builder
	b.WriteString(`{` + "\n")
	b.WriteString(`  "schema_version": 1,` + "\n")
	b.WriteString(`  "project_name": "`)
	jsonEscape(&b, m.ProjectName)
	b.WriteString(`",` + "\n")
	b.WriteString(`  "scan_date": "` + m.ScanDate + `",` + "\n")
	b.WriteString(`  "scan_commit": "` + m.ScanCommit + `",` + "\n")
	b.WriteString(`  "file_count": ` + strconv.Itoa(m.FileCount) + `,` + "\n")
	b.WriteString(`  "total_lines": ` + strconv.Itoa(m.TotalLines) + `,` + "\n")
	b.WriteString(`  "tree_lines": ` + strconv.Itoa(m.TreeLines) + `,` + "\n")
	b.WriteString(`  "doc_quality_score": ` + strconv.Itoa(m.DocQualityScore) + "\n")
	b.WriteString("}\n")
	return w.WriteAtomic(filepath.Join(indexDir, "meta.json"), []byte(b.String()))
}

// --- JSON escape -------------------------------------------------------

// jsonEscape writes s to b with the same five-character escape coverage
// as lib/common.sh::_json_escape — backslash, quote, newline, return, tab.
// Other control characters are passed through (matching bash, which is
// best-effort and not full RFC 8259).
func jsonEscape(b *strings.Builder, s string) {
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\\':
			b.WriteString(`\\`)
		case '"':
			b.WriteString(`\"`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			b.WriteByte(s[i])
		}
	}
}

// --- scan_commit helpers -----------------------------------------------

// computeScanCommit ports bash:
//   if git -C dir rev-parse --git-dir; then git rev-parse --short HEAD
//   else "non-git"
func computeScanCommit(projectDir string) string {
	if err := exec.Command("git", "-C", projectDir, "rev-parse", "--git-dir").Run(); err != nil {
		return "non-git"
	}
	out, err := exec.Command("git", "-C", projectDir, "rev-parse", "--short", "HEAD").Output()
	if err != nil {
		return "unknown"
	}
	return strings.TrimRight(string(out), "\n")
}

// computeScanDate returns the ISO-8601 UTC timestamp emitted into
// meta.json. Format mirrors bash `date -u '+%Y-%m-%dT%H:%M:%SZ'`.
func computeScanDate() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}

// --- support: line count via stream (used by orchestrator) -------------

// streamLineCount counts newline-terminated lines in r. Used by the
// orchestrator to compute MetaInputs.TreeLines from tree.txt without
// reading the whole file into memory twice.
func streamLineCount(r io.Reader) int {
	count := 0
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		count++
	}
	return count
}
