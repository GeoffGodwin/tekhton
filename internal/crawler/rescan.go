package crawler

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/detect"
)

// RescanOptions carries the rescan request. ForceFull short-circuits the
// decision tree to a full crawl regardless of git state. Other fields
// mirror crawler.Options — the rescan path always falls back to a full
// Crawl on any unrecoverable branch, so the same projectDir / budget /
// writer carry through.
type RescanOptions struct {
	ProjectDir  string
	BudgetChars int
	IndexDir    string
	Writer      Writer
	DesignFile  string

	// ForceFull bypasses every change-detection branch and runs a full
	// Crawl. Maps to the rescan CLI's --full flag.
	ForceFull bool

	// IndexFile overrides the default PROJECT_INDEX.md path used to
	// read scan metadata. Empty means
	// "<ProjectDir>/.tekhton/PROJECT_INDEX.md" — matches the bash
	// PROJECT_INDEX_FILE default.
	IndexFile string

	// ScanDate / ScanCommit are deterministic-test injections — empty
	// means "compute live". Forwarded to Crawl on full-crawl branches
	// and stamped into meta.json on the incremental branch.
	ScanDate   string
	ScanCommit string
}

// Result of a rescan. Mode indicates which decision-tree branch fired:
//   - "noop"         — no changes since last scan; nothing was written.
//   - "incremental"  — selective regeneration of affected sections.
//   - "full"         — full crawl (forced, or fell back from a branch).
//
// FullCrawl, when non-nil, is the underlying crawler.Result for the
// full-crawl branch (lets callers surface file counts, errors, etc.).
//
// FallbackReason is a short human-readable description of why a full
// crawl was chosen — populated when Mode == "full" AND ForceFull was
// false. Used by the CLI for logging only.
type RescanResult struct {
	Mode           string
	FullCrawl      *Result
	FallbackReason string
	Changes        []Change
	Significance   Significance
	// RegeneratedSections lists the per-section artifacts the
	// incremental path actually rewrote (tree, inventory, deps, configs,
	// samples, meta). Always populated for Mode=="incremental"; nil
	// otherwise.
	RegeneratedSections []string
}

// NoOp returns true when the rescan determined the index was already
// up-to-date and wrote nothing. The CLI uses this to emit the same
// "Index is up to date" line the bash version printed.
func (r *RescanResult) NoOp() bool {
	return r != nil && r.Mode == "noop"
}

// defaultIndexFile returns the bash PROJECT_INDEX_FILE default —
// `.tekhton/PROJECT_INDEX.md` under projectDir.
func defaultIndexFile(projectDir string) string {
	return filepath.Join(projectDir, ".tekhton", "PROJECT_INDEX.md")
}

// asCrawlOptions converts RescanOptions to Options for the full-crawl
// fallback paths. The Writer carries through so tests can assert
// write-set behaviour on the fallback branches too.
func (o RescanOptions) asCrawlOptions() Options {
	return Options{
		ProjectDir:  o.ProjectDir,
		BudgetChars: o.BudgetChars,
		IndexDir:    o.IndexDir,
		Writer:      o.Writer,
		DesignFile:  o.DesignFile,
		ScanDate:    o.ScanDate,
		ScanCommit:  o.ScanCommit,
	}
}

// Rescan ports rescan.sh::rescan_project. The eight-branch decision
// tree is preserved 1:1 by line order — each branch either falls back
// to a full Crawl or proceeds further. The final branch performs the
// selective incremental regeneration via updateIndexSections.
//
// Branch order is load-bearing — do not "tidy up" into a switch.
// Reordering changes the user-visible log line and the parity gate.
func Rescan(ctx context.Context, opts RescanOptions) (*RescanResult, error) {
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
	if opts.IndexFile == "" {
		opts.IndexFile = defaultIndexFile(opts.ProjectDir)
	}
	if opts.Writer == nil {
		opts.Writer = fsWriter{}
	}

	// Branch 1: --full forces full crawl.
	if opts.ForceFull {
		return rescanFallToFull(ctx, opts, "forced")
	}

	// Branch 2: no existing index file.
	if !fileExists(opts.IndexFile) {
		return rescanFallToFull(ctx, opts, "no existing index")
	}

	// Branch 3: no structured meta.json — migration full crawl.
	metaFile := filepath.Join(opts.IndexDir, "meta.json")
	if !fileExists(metaFile) {
		return rescanFallToFull(ctx, opts, "no structured index (meta.json missing)")
	}

	// Branch 4: not a git repo.
	if !isGitRepo(ctx, opts.ProjectDir) {
		return rescanFallToFull(ctx, opts, "not a git repository")
	}

	// Branch 5: no recorded scan commit. Read meta.json directly from the
	// known IndexDir — the public ExtractScanMetadata mirrors bash's
	// `dirname(indexFile) + .claude/index/meta.json` quirk, which is
	// load-bearing for replan_brownfield.sh callers but wrong for our
	// internal use where we already know the IndexDir explicitly.
	lastScanCommit := strings.TrimSpace(readMetaJSONFieldByPublicName(metaFile, "Scan-Commit"))
	if lastScanCommit == "" {
		// Fallback to the legacy HTML-comment header in the index file
		// (pre-M68 projects). Honors the bash legacy-fallback contract.
		lastScanCommit = strings.TrimSpace(extractHTMLCommentField(opts.IndexFile, "Scan-Commit"))
	}
	if lastScanCommit == "" || lastScanCommit == "non-git" {
		return rescanFallToFull(ctx, opts, "no scan commit recorded")
	}

	// Branch 6: recorded commit no longer exists (rebased away).
	if !gitCommitExists(ctx, opts.ProjectDir, lastScanCommit) {
		return rescanFallToFull(ctx, opts,
			fmt.Sprintf("recorded scan commit %s no longer exists", lastScanCommit))
	}

	// Branch 7: no changes since last scan.
	changes, err := DetectChangedFiles(ctx, opts.ProjectDir, lastScanCommit)
	if err != nil {
		return nil, err
	}
	if len(changes) == 0 {
		return &RescanResult{Mode: "noop", Significance: Trivial}, nil
	}

	// Branch 8: major changes → full crawl for accuracy.
	sig := ClassifyChanges(changes)
	if sig == Major {
		res, err := rescanFallToFull(ctx, opts, "major structural changes detected")
		if err != nil {
			return nil, err
		}
		res.Changes = changes
		res.Significance = Major
		return res, nil
	}

	// Incremental path.
	return updateIndexSections(ctx, opts, changes, sig)
}

// rescanFallToFull runs the full Crawl and wraps the result as a
// RescanResult with Mode="full". Used by every fallback branch — the
// reason argument is recorded so the CLI can surface why.
//
// Crawl can return (nil, err) on context cancellation or a missing
// project dir — those errors propagate to the caller so the CLI does
// not silently announce a successful full crawl when nothing was
// written. When Crawl returns (non-nil, err) the partial Result is
// surfaced as FullCrawl and the error is swallowed: the rescan layer
// has no Errors field to attach it to, and callers that need
// per-section failure detail can introspect FullCrawl.
func rescanFallToFull(ctx context.Context, opts RescanOptions, reason string) (*RescanResult, error) {
	cr, err := Crawl(ctx, opts.asCrawlOptions())
	if cr == nil && err != nil {
		return nil, err
	}
	r := &RescanResult{Mode: "full", FullCrawl: cr}
	if !opts.ForceFull {
		r.FallbackReason = reason
	}
	return r, nil
}

// updateIndexSections runs the selective regeneration path — the only
// non-full-crawl branch of the rescan tree. Ports the bash logic in
// rescan.sh::_update_index_sections:
//
//   - ANY change triggers inventory regen.
//   - A/D under non-"." dirs or R sets has_new_dirs → tree regen.
//   - Any manifest-file change sets has_manifest_change → deps regen.
//   - Any config-file change sets has_config_change → configs regen.
//   - Any currently-sampled file in the change set OR any newly-added
//     high-priority file (.md/.json/.toml/.yaml/.yml) triggers samples
//     regen.
//   - meta.json is ALWAYS rewritten (scan date / commit refresh).
//
// The view regeneration step (bash:
// `generate_project_index_view "$project_dir" "$budget_chars"`) is
// intentionally NOT performed here. The Go rescan path stops at the
// structured-artifact boundary; the legacy bash shim caller invokes
// the view generator itself. This matches the m30.1 boundary the
// crawler core established.
func updateIndexSections(ctx context.Context, opts RescanOptions, changes []Change, sig Significance) (*RescanResult, error) {
	regen := newRegenSetWithIndexDir(opts.IndexFile, opts.IndexDir, changes)

	// Inventory is the file-list-derived artifact every other section
	// reuses; load the file list once.
	files := listTrackedFiles(opts.ProjectDir)
	indexDir := opts.IndexDir

	var rewrote []string

	if regen.tree {
		if err := emitTreeTxt(opts.Writer, indexDir, crawlDirectoryTree(opts.ProjectDir, 6)); err != nil {
			return nil, fmt.Errorf("rescan tree: %w", err)
		}
		rewrote = append(rewrote, "tree.txt")
	}

	// Inventory is computed regardless because both meta.json (file
	// counts) and the samples path need it. Only WRITE it when
	// regen.inventory is set.
	inv := buildFileInventory(opts.ProjectDir, files)
	if regen.inventory {
		if err := emitInventoryJSONL(opts.Writer, indexDir, inv); err != nil {
			return nil, fmt.Errorf("rescan inventory: %w", err)
		}
		rewrote = append(rewrote, "inventory.jsonl")
	}

	if regen.deps {
		g, _ := parseDependencies(opts.ProjectDir)
		if err := emitDependenciesJSON(opts.Writer, indexDir, g); err != nil {
			return nil, fmt.Errorf("rescan deps: %w", err)
		}
		rewrote = append(rewrote, "dependencies.json")
	}

	if regen.configs {
		cfg := buildConfigInventory(files)
		if err := emitConfigsJSON(opts.Writer, indexDir, cfg); err != nil {
			return nil, fmt.Errorf("rescan configs: %w", err)
		}
		rewrote = append(rewrote, "configs.json")
	}

	if regen.samples {
		if err := opts.Writer.EnsureSamplesDir(filepath.Join(indexDir, "samples")); err != nil {
			return nil, fmt.Errorf("rescan samples dir: %w", err)
		}
		sampleBudget := opts.BudgetChars * 55 / 100
		samples := sampleFiles(opts.ProjectDir, files, sampleBudget, opts.DesignFile)
		total := 0
		for _, s := range samples {
			total += s.Chars
		}
		if err := emitSamples(opts.Writer, indexDir, samples, total, sampleBudget); err != nil {
			return nil, fmt.Errorf("rescan samples: %w", err)
		}
		// emitSamples writes both individual files AND manifest.json;
		// the parity gate tracks manifest.json as the canonical entry.
		rewrote = append(rewrote, "samples/manifest.json")
	}

	// meta.json always refreshes — scan date / scan commit move forward.
	fileCount := len(inv.Entries)
	totalLines := 0
	for _, e := range inv.Entries {
		totalLines += e.Lines
	}
	treeLines := countTreeLines(filepath.Join(indexDir, "tree.txt"))
	scanDate := opts.ScanDate
	if scanDate == "" {
		scanDate = computeScanDate()
	}
	scanCommit := opts.ScanCommit
	if scanCommit == "" {
		scanCommit = computeScanCommit(opts.ProjectDir)
	}
	docQuality := 0
	if dq := detect.AssessDocQuality(opts.ProjectDir); dq != nil {
		docQuality = dq.Score
	}
	meta := MetaInputs{
		ProjectName:     filepath.Base(opts.ProjectDir),
		ScanDate:        scanDate,
		ScanCommit:      scanCommit,
		FileCount:       fileCount,
		TotalLines:      totalLines,
		TreeLines:       treeLines,
		DocQualityScore: docQuality,
	}
	if err := emitMetaJSON(opts.Writer, indexDir, meta); err != nil {
		return nil, fmt.Errorf("rescan meta: %w", err)
	}
	rewrote = append(rewrote, "meta.json")

	return &RescanResult{
		Mode:                "incremental",
		Changes:             changes,
		Significance:        sig,
		RegeneratedSections: rewrote,
	}, nil
}

// regenSet records which sections need rewriting for a given change
// set. Computed in one pass over the changes; consumed by
// updateIndexSections to drive the conditional emit blocks.
type regenSet struct {
	tree      bool
	inventory bool
	deps      bool
	configs   bool
	samples   bool
}

// newRegenSet ports the decision logic in
// rescan.sh::_update_index_sections lines 130-175. ANY change forces
// inventory regen; the other flags depend on what kind of change
// landed.
//
// indexDir is the canonical samples-manifest source (the bash-bug-
// compatible ExtractSampledFiles would mis-resolve when indexFile lives
// in `.tekhton/`; Rescan knows the real IndexDir explicitly).
func newRegenSetWithIndexDir(indexFile, indexDir string, changes []Change) regenSet {
	r := regenSet{}
	var hasNewDirs, hasManifestChange, hasConfigChange bool

	for _, c := range changes {
		r.inventory = true
		if c.Status == "" {
			continue
		}
		switch c.Status[0] {
		case 'A', 'D':
			if filepath.Dir(c.Path) != "." {
				hasNewDirs = true
			}
		case 'R':
			hasNewDirs = true
		}
		if IsManifestFile(c.Path) {
			hasManifestChange = true
		}
		if IsConfigFile(c.Path) {
			hasConfigChange = true
		}
	}
	r.tree = hasNewDirs
	r.deps = hasManifestChange
	r.configs = hasConfigChange

	// Samples regen triggers — either a currently-sampled file is in
	// the change set, or a newly-added high-priority file should be
	// reconsidered for sampling.
	currentSamples := readSamplesManifestFromIndexDir(indexDir, indexFile)
	if sampledFileTouched(currentSamples, changes) {
		r.samples = true
	}
	if !r.samples && highPriorityAdded(changes) {
		r.samples = true
	}
	return r
}

// readSamplesManifestFromIndexDir reads samples/manifest.json directly
// from indexDir (bypassing the bash-bug-compatible dirname trick),
// falling back to the legacy markdown headings via ExtractSampledFiles
// for pre-M68 projects where samples/manifest.json doesn't exist.
func readSamplesManifestFromIndexDir(indexDir, indexFile string) []string {
	manifest := filepath.Join(indexDir, "samples", "manifest.json")
	if fileExists(manifest) {
		// Use the public function with a synthesized index file path
		// rooted in the parent of indexDir so the dirname trick lands
		// on the right meta location. ProjectIndexFile name is
		// arbitrary — only the parent dir matters.
		synthIndex := filepath.Join(filepath.Dir(filepath.Dir(indexDir)), "PROJECT_INDEX.md")
		_ = synthIndex
		// Read manifest directly to avoid the bash-bug path quirk.
		samples := decodeSamplesManifest(manifest)
		if samples != nil {
			return samples
		}
	}
	// Legacy fallback path goes through the bash-quirky function.
	return ExtractSampledFiles(indexFile)
}

// sampledFileTouched returns true when any currently-sampled file
// appears in the change set. Mirrors the bash `grep -qF "$sample"` per
// sample.
func sampledFileTouched(currentSamples []string, changes []Change) bool {
	if len(currentSamples) == 0 || len(changes) == 0 {
		return false
	}
	changeSet := make(map[string]struct{}, len(changes))
	for _, c := range changes {
		changeSet[c.Path] = struct{}{}
		if c.RenameTo != "" {
			changeSet[c.RenameTo] = struct{}{}
		}
	}
	for _, s := range currentSamples {
		if _, ok := changeSet[s]; ok {
			return true
		}
	}
	return false
}

// highPriorityAdded returns true when any A-status change is a
// high-priority sample candidate (.md, .json, .toml, .yaml, .yml).
// Mirrors `grep -qE '^A.*\.(md|json|toml|yaml|yml)$'` in the bash.
func highPriorityAdded(changes []Change) bool {
	for _, c := range changes {
		if c.Status == "" || c.Status[0] != 'A' {
			continue
		}
		switch strings.ToLower(filepath.Ext(c.Path)) {
		case ".md", ".json", ".toml", ".yaml", ".yml":
			return true
		}
	}
	return false
}

// fileExists is a small helper for the decision-tree presence checks.
// Returns false on any error (matches bash `[[ -f X ]]` semantics).
func fileExists(path string) bool {
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	return !st.IsDir()
}

// Sentinels for callers that want to assert on rescan-specific failure
// modes via errors.Is. Currently only one — ErrMissingProjectDir is
// reused from crawler.go.
var _ = errors.New
