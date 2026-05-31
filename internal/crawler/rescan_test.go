package crawler

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// setupRescanRepo creates a minimal project with a git history and a
// pre-existing .claude/index/ artifact set. Returns the project dir and
// the recorded scan commit (short SHA) that lives in meta.json.
//
// The seed artifacts are added to .gitignore so they don't show up as
// untracked files in `git status --porcelain` — otherwise every rescan
// would see ~10 phantom "new files" and never reach the noop branch.
func setupRescanRepo(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	_ = gitInit(t, dir)

	// Ignore the index + tekhton artifacts so DetectChangedFiles returns
	// zero changes when the user hasn't actually touched source.
	mustWrite(t, filepath.Join(dir, ".gitignore"), ".claude/\n.tekhton/\n")
	gitRun(t, dir, "add", ".gitignore")
	gitRun(t, dir, "commit", "-q", "-m", "ignore")

	// HEAD now points to the post-ignore commit; use that for scan_commit
	// so a clean rescan sees no changes.
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--short", "HEAD").Output()
	if err != nil {
		t.Fatal(err)
	}
	sha := strings.TrimSpace(string(out))

	indexDir := filepath.Join(dir, ".claude", "index")
	if err := os.MkdirAll(filepath.Join(indexDir, "samples"), 0o755); err != nil {
		t.Fatal(err)
	}

	// Seed the structured artifacts the rescan branches gate on.
	mustWrite(t, filepath.Join(indexDir, "meta.json"),
		`{"schema_version":1,"scan_commit":"`+sha+`","file_count":1}`+"\n")
	mustWrite(t, filepath.Join(indexDir, "tree.txt"), ".\n└── README.md\n")
	mustWrite(t, filepath.Join(indexDir, "inventory.jsonl"),
		`{"path":"README.md","dir":".","lines":1,"size":"tiny"}`+"\n")
	mustWrite(t, filepath.Join(indexDir, "dependencies.json"),
		"{\n  \"manifests\": [\n  ],\n  \"key_dependencies\": [\n  ]\n}\n")
	mustWrite(t, filepath.Join(indexDir, "configs.json"), "{\n  \"configs\": [\n  ]\n}\n")
	mustWrite(t, filepath.Join(indexDir, "samples", "manifest.json"),
		`{"samples":[{"original":"README.md","stored":"README.md.txt","chars":1}],"total_chars":1,"budget_chars":1000}`+"\n")

	// Default PROJECT_INDEX_FILE path.
	tekhtonDir := filepath.Join(dir, ".tekhton")
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(tekhtonDir, "PROJECT_INDEX.md"), "# index\n")
	return dir, sha
}

// gitRun is a fixture helper that fails the test on error.
func gitRun(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=test", "GIT_AUTHOR_EMAIL=t@e",
		"GIT_COMMITTER_NAME=test", "GIT_COMMITTER_EMAIL=t@e",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

func mustWrite(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRescanRejectsMissingProjectDir(t *testing.T) {
	_, err := Rescan(context.Background(), RescanOptions{})
	if err != ErrMissingProjectDir {
		t.Errorf("expected ErrMissingProjectDir, got %v", err)
	}
}

func TestRescanBranchForceFull(t *testing.T) {
	dir, _ := setupRescanRepo(t)
	r, err := Rescan(context.Background(), RescanOptions{
		ProjectDir: dir,
		ForceFull:  true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if r.Mode != "full" {
		t.Errorf("expected full mode, got %s", r.Mode)
	}
	if r.FallbackReason != "" {
		t.Errorf("forced full should leave FallbackReason empty, got %q", r.FallbackReason)
	}
}

func TestRescanBranchNoIndexFile(t *testing.T) {
	dir := t.TempDir()
	r, err := Rescan(context.Background(), RescanOptions{ProjectDir: dir})
	if err != nil {
		t.Fatal(err)
	}
	if r.Mode != "full" {
		t.Errorf("expected full fallback, got %s", r.Mode)
	}
	if !strings.Contains(r.FallbackReason, "no existing index") {
		t.Errorf("expected reason about missing index, got %q", r.FallbackReason)
	}
}

func TestRescanBranchNoStructuredMeta(t *testing.T) {
	dir := t.TempDir()
	tekhtonDir := filepath.Join(dir, ".tekhton")
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(tekhtonDir, "PROJECT_INDEX.md"), "# index\n")
	r, err := Rescan(context.Background(), RescanOptions{ProjectDir: dir})
	if err != nil {
		t.Fatal(err)
	}
	if r.Mode != "full" || !strings.Contains(r.FallbackReason, "meta.json") {
		t.Errorf("expected meta.json fallback, got mode=%s reason=%q", r.Mode, r.FallbackReason)
	}
}

func TestRescanBranchNotGitRepo(t *testing.T) {
	dir := t.TempDir()
	tekhtonDir := filepath.Join(dir, ".tekhton")
	indexDir := filepath.Join(dir, ".claude", "index")
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(indexDir, 0o755); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(tekhtonDir, "PROJECT_INDEX.md"), "# index\n")
	mustWrite(t, filepath.Join(indexDir, "meta.json"), `{"schema_version":1}`+"\n")
	r, err := Rescan(context.Background(), RescanOptions{ProjectDir: dir})
	if err != nil {
		t.Fatal(err)
	}
	if r.Mode != "full" {
		t.Errorf("expected full fallback on non-git tree, got %s", r.Mode)
	}
	if !strings.Contains(r.FallbackReason, "not a git repository") {
		t.Errorf("expected git fallback reason, got %q", r.FallbackReason)
	}
}

func TestRescanBranchNoScanCommit(t *testing.T) {
	dir, _ := setupRescanRepo(t)
	// Overwrite meta.json with no scan_commit.
	mustWrite(t, filepath.Join(dir, ".claude", "index", "meta.json"),
		`{"schema_version":1}`+"\n")
	r, err := Rescan(context.Background(), RescanOptions{ProjectDir: dir})
	if err != nil {
		t.Fatal(err)
	}
	if r.Mode != "full" || !strings.Contains(r.FallbackReason, "no scan commit") {
		t.Errorf("expected no-scan-commit fallback, got mode=%s reason=%q", r.Mode, r.FallbackReason)
	}
}

func TestRescanBranchScanCommitNonGit(t *testing.T) {
	dir, _ := setupRescanRepo(t)
	mustWrite(t, filepath.Join(dir, ".claude", "index", "meta.json"),
		`{"schema_version":1,"scan_commit":"non-git"}`+"\n")
	r, err := Rescan(context.Background(), RescanOptions{ProjectDir: dir})
	if err != nil {
		t.Fatal(err)
	}
	if r.Mode != "full" {
		t.Errorf("expected non-git scan commit to fall back to full, got %s", r.Mode)
	}
}

func TestRescanBranchCommitRebasedAway(t *testing.T) {
	dir, _ := setupRescanRepo(t)
	// Use a fake-looking SHA that doesn't exist in this repo.
	mustWrite(t, filepath.Join(dir, ".claude", "index", "meta.json"),
		`{"schema_version":1,"scan_commit":"abcdef0"}`+"\n")
	r, err := Rescan(context.Background(), RescanOptions{ProjectDir: dir})
	if err != nil {
		t.Fatal(err)
	}
	if r.Mode != "full" || !strings.Contains(r.FallbackReason, "no longer exists") {
		t.Errorf("expected rebased-away fallback, got mode=%s reason=%q", r.Mode, r.FallbackReason)
	}
}

func TestRescanBranchNoChangesIsNoop(t *testing.T) {
	dir, _ := setupRescanRepo(t)
	r, err := Rescan(context.Background(), RescanOptions{ProjectDir: dir})
	if err != nil {
		t.Fatal(err)
	}
	if r.Mode != "noop" {
		t.Errorf("expected noop on clean tree, got %s", r.Mode)
	}
	if !r.NoOp() {
		t.Errorf("NoOp() should be true")
	}
}

func TestRescanBranchMajorTriggersFullCrawl(t *testing.T) {
	dir, _ := setupRescanRepo(t)
	// Touch 2+ manifests to trigger major. Both need to be untracked so
	// they show up in the change set as A entries with manifest paths.
	mustWrite(t, filepath.Join(dir, "package.json"), "{\n}\n")
	mustWrite(t, filepath.Join(dir, "Cargo.toml"), "[package]\nname='x'\n")

	r, err := Rescan(context.Background(), RescanOptions{ProjectDir: dir})
	if err != nil {
		t.Fatal(err)
	}
	if r.Mode != "full" || r.Significance != Major {
		t.Errorf("expected major→full, got mode=%s sig=%v", r.Mode, r.Significance)
	}
	if !strings.Contains(r.FallbackReason, "major structural changes") {
		t.Errorf("expected FallbackReason to mention 'major structural changes', got %q", r.FallbackReason)
	}
}

func TestRescanBranchTrivialIncremental(t *testing.T) {
	dir, _ := setupRescanRepo(t)
	w := newRecordingWriter(filepath.Join(dir, ".claude", "index"))
	// One trivial edit to an existing tracked file.
	mustWrite(t, filepath.Join(dir, "README.md"), "# changed\n")

	r, err := Rescan(context.Background(), RescanOptions{
		ProjectDir: dir,
		Writer:     w,
		ScanDate:   "FROZEN", ScanCommit: "FROZEN",
	})
	if err != nil {
		t.Fatal(err)
	}
	if r.Mode != "incremental" {
		t.Fatalf("expected incremental, got mode=%s", r.Mode)
	}
	if r.Significance != Trivial {
		t.Errorf("expected Trivial, got %v", r.Significance)
	}

	wrote := make(map[string]bool)
	for _, w := range w.writes {
		wrote[filepath.Base(w.Name)] = true
	}
	// Inventory and meta MUST regenerate; tree / deps / configs MUST NOT.
	if !wrote["inventory.jsonl"] {
		t.Errorf("trivial change should regen inventory.jsonl; writes: %v", wrote)
	}
	if !wrote["meta.json"] {
		t.Errorf("any rescan should refresh meta.json; writes: %v", wrote)
	}
	if wrote["tree.txt"] {
		t.Errorf("trivial change should NOT regen tree.txt")
	}
	if wrote["dependencies.json"] {
		t.Errorf("trivial change should NOT regen dependencies.json")
	}
	if wrote["configs.json"] {
		t.Errorf("trivial change should NOT regen configs.json")
	}
	// README.md is in samples/manifest.json — a sampled-file touch MUST
	// trigger samples regeneration.
	if !wrote["manifest.json"] {
		t.Errorf("README.md is sampled; trivial edit should regen samples/manifest.json; writes: %v", wrote)
	}
}

func TestRescanBranchModerateManifest(t *testing.T) {
	dir, sha := setupRescanRepo(t)
	// Stage a package.json edit. Single manifest = moderate, not major.
	mustWrite(t, filepath.Join(dir, "package.json"),
		"{\n  \"name\": \"x\",\n  \"dependencies\": {}\n}\n")

	w := newRecordingWriter(filepath.Join(dir, ".claude", "index"))
	r, err := Rescan(context.Background(), RescanOptions{
		ProjectDir: dir,
		Writer:     w,
		ScanDate:   "FROZEN", ScanCommit: "FROZEN",
	})
	if err != nil {
		t.Fatalf("rescan: %v (sha=%s)", err, sha)
	}
	if r.Mode != "incremental" {
		t.Fatalf("expected incremental, got %s", r.Mode)
	}
	if r.Significance != Moderate {
		t.Errorf("expected Moderate, got %v", r.Significance)
	}

	wrote := make(map[string]bool)
	for _, w := range w.writes {
		wrote[filepath.Base(w.Name)] = true
	}
	// dependencies.json + inventory + meta must regenerate; tree must not.
	if !wrote["dependencies.json"] {
		t.Errorf("manifest change should regen dependencies.json; writes: %v", wrote)
	}
	if !wrote["inventory.jsonl"] {
		t.Errorf("ANY change should regen inventory.jsonl")
	}
	if !wrote["meta.json"] {
		t.Errorf("meta always regen")
	}
	if wrote["tree.txt"] {
		t.Errorf("moderate-manifest (no new dir) should NOT regen tree.txt")
	}
}

func TestRescanIncrementalRegeneratesSamplesWhenSampledFileChanges(t *testing.T) {
	dir, _ := setupRescanRepo(t)
	// README.md is in the seeded samples/manifest.json — touching it
	// must trigger samples regen.
	mustWrite(t, filepath.Join(dir, "README.md"), "# different\n")

	w := newRecordingWriter(filepath.Join(dir, ".claude", "index"))
	r, err := Rescan(context.Background(), RescanOptions{
		ProjectDir: dir,
		Writer:     w,
		ScanDate:   "FROZEN", ScanCommit: "FROZEN",
	})
	if err != nil {
		t.Fatal(err)
	}
	if r.Mode != "incremental" {
		t.Fatalf("expected incremental, got %s", r.Mode)
	}
	found := false
	for _, s := range r.RegeneratedSections {
		if strings.Contains(s, "samples") {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("touching a sampled file should regen samples; RegeneratedSections=%v",
			r.RegeneratedSections)
	}
}

func TestRescanIncrementalRegeneratesSamplesWhenHighPriorityAdded(t *testing.T) {
	dir, _ := setupRescanRepo(t)
	// Add an untracked .md file — should trigger samples regen.
	mustWrite(t, filepath.Join(dir, "NEW.md"), "# new\n")

	w := newRecordingWriter(filepath.Join(dir, ".claude", "index"))
	r, err := Rescan(context.Background(), RescanOptions{
		ProjectDir: dir,
		Writer:     w,
		ScanDate:   "FROZEN", ScanCommit: "FROZEN",
	})
	if err != nil {
		t.Fatal(err)
	}
	if r.Mode != "incremental" {
		t.Fatalf("expected incremental, got %s", r.Mode)
	}
	found := false
	for _, s := range r.RegeneratedSections {
		if strings.Contains(s, "samples") {
			found = true
		}
	}
	if !found {
		t.Errorf("adding high-priority .md should regen samples; RegeneratedSections=%v",
			r.RegeneratedSections)
	}
}

func TestNewRegenSetInventoryAlwaysTriggers(t *testing.T) {
	rs := newRegenSetWithIndexDir("", "", []Change{{Status: "M", Path: "x"}})
	if !rs.inventory {
		t.Errorf("any change should set inventory regen")
	}
}

func TestSampledFileTouched(t *testing.T) {
	if sampledFileTouched(nil, []Change{{Status: "M", Path: "x"}}) {
		t.Errorf("no samples → never triggered")
	}
	if sampledFileTouched([]string{"a"}, nil) {
		t.Errorf("no changes → never triggered")
	}
	if !sampledFileTouched([]string{"a"}, []Change{{Status: "M", Path: "a"}}) {
		t.Errorf("matching sample MUST trigger")
	}
}

func TestHighPriorityAdded(t *testing.T) {
	if !highPriorityAdded([]Change{{Status: "A", Path: "x.md"}}) {
		t.Errorf("A *.md should trigger")
	}
	if highPriorityAdded([]Change{{Status: "M", Path: "x.md"}}) {
		t.Errorf("M (not A) should NOT trigger")
	}
	if highPriorityAdded([]Change{{Status: "A", Path: "x.go"}}) {
		t.Errorf(".go is not high-priority")
	}
}

func TestFileExistsHandlesDirAndMissing(t *testing.T) {
	dir := t.TempDir()
	if fileExists(filepath.Join(dir, "nope")) {
		t.Errorf("missing should be false")
	}
	if fileExists(dir) {
		t.Errorf("dir should be false (file-only check)")
	}
	p := filepath.Join(dir, "x")
	if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !fileExists(p) {
		t.Errorf("real file should be true")
	}
}

// ensureGitAvailable skips if git isn't on the path — every Rescan
// branch that hits git falls back to "not a git repo" without it.
func ensureGitAvailable(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
}
