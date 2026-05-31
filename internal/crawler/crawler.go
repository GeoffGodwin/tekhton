package crawler

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/detect"
)

// Options carries the crawl request — project root, target index dir,
// total char budget, and an optional Writer for tests.
//
// Writer defaults to fsWriter (atomic temp-file + rename under IndexDir).
// IndexDir defaults to ProjectDir + "/.claude/index".
// BudgetChars defaults to 120000 to match PROJECT_INDEX_BUDGET.
type Options struct {
	ProjectDir   string
	BudgetChars  int
	IndexDir     string
	Writer       Writer
	// DesignFile maps to $DESIGN_FILE — the architecture-doc sample
	// candidate. Empty when unset.
	DesignFile string
	// ScanDate / ScanCommit can be injected by parity tests to make the
	// run deterministic. Empty means "compute live."
	ScanDate   string
	ScanCommit string
}

// Result is the post-crawl summary surfaced to the caller (and to the
// CLI's --json output).
type Result struct {
	IndexDir       string
	FileCount      int
	TotalLines     int
	TreeLines      int
	Manifests      []Manifest
	KeyDeps        []Dependency
	DocQuality     int
	Errors         []error
	// SamplesUsed is the total characters across emitted samples; tests
	// use it to assert the budget allocator behaved.
	SamplesUsed int
}

// ErrMissingProjectDir is returned when Options.ProjectDir is unset.
var ErrMissingProjectDir = errors.New("crawler: ProjectDir is required")

// Crawl produces the .claude/index/ artifact set for a project. Phase 1
// emits structured data (tree, inventory, deps, configs, tests, samples,
// meta — in that order so meta can read counts from inventory.jsonl).
// Phase 2 — view regeneration — is delegated to the bash
// generate_project_index_view until m31+ ports the index-view subsystem.
//
// The function is read-only on ProjectDir and write-only on IndexDir.
// Callers should treat partial failures (non-nil error returned with a
// non-nil Result) as "best effort completed"; the bash version warns on
// per-phase failures but continues, and this port follows that pattern.
func Crawl(ctx context.Context, opts Options) (*Result, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if opts.ProjectDir == "" {
		return nil, ErrMissingProjectDir
	}
	if opts.BudgetChars <= 0 {
		opts.BudgetChars = 120_000
	}
	if opts.IndexDir == "" {
		opts.IndexDir = filepath.Join(opts.ProjectDir, ".claude", "index")
	}
	if opts.Writer == nil {
		opts.Writer = fsWriter{}
	}
	if err := os.MkdirAll(filepath.Join(opts.IndexDir, "samples"), 0o755); err != nil {
		return nil, fmt.Errorf("crawler: ensure index dir: %w", err)
	}

	result := &Result{IndexDir: opts.IndexDir}

	// Single file-list call serves every downstream phase. Mirrors the
	// M67 fix that collapsed four separate enumerations into one.
	files := listTrackedFiles(opts.ProjectDir)

	// Doc quality (computed once, passed to meta).
	if dq := detect.AssessDocQuality(opts.ProjectDir); dq != nil {
		result.DocQuality = dq.Score
	}

	// Phase 1 — emit structured data files in dependency order.
	treeContent := crawlDirectoryTree(opts.ProjectDir, 6)
	if err := emitTreeTxt(opts.Writer, opts.IndexDir, treeContent); err != nil {
		result.Errors = append(result.Errors, err)
	}

	inv := buildFileInventory(opts.ProjectDir, files)
	if err := emitInventoryJSONL(opts.Writer, opts.IndexDir, inv); err != nil {
		result.Errors = append(result.Errors, err)
	}

	graph, _ := parseDependencies(opts.ProjectDir)
	result.Manifests = graph.Manifests
	result.KeyDeps = graph.KeyDependencies
	if err := emitDependenciesJSON(opts.Writer, opts.IndexDir, graph); err != nil {
		result.Errors = append(result.Errors, err)
	}

	cfg := buildConfigInventory(files)
	if err := emitConfigsJSON(opts.Writer, opts.IndexDir, cfg); err != nil {
		result.Errors = append(result.Errors, err)
	}

	tests := buildTestStructure(opts.ProjectDir, files)
	if err := emitTestsJSON(opts.Writer, opts.IndexDir, tests); err != nil {
		result.Errors = append(result.Errors, err)
	}

	// Samples — budget is 55% of total (matches the bash
	// _emit_sampled_files allocation). Sample emission is the last
	// content-bearing step before meta because samples don't affect
	// inventory counts and meta needs the counts.
	sampleBudget := opts.BudgetChars * 55 / 100
	samples := sampleFiles(opts.ProjectDir, files, sampleBudget, opts.DesignFile)
	totalSampleChars := 0
	for _, s := range samples {
		totalSampleChars += s.Chars
	}
	result.SamplesUsed = totalSampleChars
	if err := emitSamples(opts.Writer, opts.IndexDir, samples, totalSampleChars, sampleBudget); err != nil {
		result.Errors = append(result.Errors, err)
	}

	// Compute MetaInputs from the just-emitted artifacts so file_count
	// and total_lines reflect actual on-disk state — mirrors bash
	// _emit_meta_json's wc-on-inventory.jsonl approach.
	fileCount := len(inv.Entries)
	totalLines := 0
	for _, e := range inv.Entries {
		totalLines += e.Lines
	}
	treeLines := countTreeLines(filepath.Join(opts.IndexDir, "tree.txt"))
	result.FileCount = fileCount
	result.TotalLines = totalLines
	result.TreeLines = treeLines

	scanDate := opts.ScanDate
	if scanDate == "" {
		scanDate = computeScanDate()
	}
	scanCommit := opts.ScanCommit
	if scanCommit == "" {
		scanCommit = computeScanCommit(opts.ProjectDir)
	}

	meta := MetaInputs{
		ProjectName:     filepath.Base(opts.ProjectDir),
		ScanDate:        scanDate,
		ScanCommit:      scanCommit,
		FileCount:       fileCount,
		TotalLines:      totalLines,
		TreeLines:       treeLines,
		DocQualityScore: result.DocQuality,
	}
	if err := emitMetaJSON(opts.Writer, opts.IndexDir, meta); err != nil {
		result.Errors = append(result.Errors, err)
	}

	// Phase 2 — view regeneration. m31+ owns this; for now log a TODO
	// via a returned-error sentinel. The caller (lib/init.sh after the
	// shim rewire) calls generate_project_index_view directly so the
	// PROJECT_INDEX.md still gets produced. Do NOT attempt to exec the
	// bash function from here — it would re-enter the bash pipeline
	// and break the clean Go boundary the wedge milestone establishes.

	if len(result.Errors) > 0 {
		// Return the first error so the CLI exit code reflects failure;
		// the Result still contains the full Errors slice for the JSON
		// emitter.
		return result, result.Errors[0]
	}
	return result, nil
}

// countTreeLines re-opens tree.txt and counts newlines. Cheap (single
// pass) but goes through the filesystem so it sees what was actually
// written — important for parity with bash `wc -l < tree.txt`.
func countTreeLines(path string) int {
	f, err := os.Open(path)
	if err != nil {
		return 0
	}
	defer f.Close()
	return streamLineCount(f)
}
