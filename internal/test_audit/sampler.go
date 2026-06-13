package test_audit

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// historyEntry is the wire shape written to test_audit_history.jsonl. One
// entry per file, appended after a successful audit (PASS, CONCERNS, or
// successful re-audit after NEEDS_WORK rework).
type historyEntry struct {
	Timestamp string `json:"ts"`
	File      string `json:"file"`
}

// SamplerOptions carries the per-run knobs for the M89 rolling sampler.
// Defaults mirror lib/test_audit_sampler.sh constants.
type SamplerOptions struct {
	K           int
	MaxRecords  int
	HistoryFile string
}

// epochNeverAuditedTimestamp is the sentinel value assigned to files that
// have never been audited. Sorts before any real ISO-8601 timestamp.
const epochNeverAuditedTimestamp = "0000-00-00T00:00:00Z"

// EnsureHistoryFile resolves the audit history JSONL path under the
// project's cache directory. Mirrors lib/test_audit_sampler.sh's
// _ensure_test_audit_history_file: uses REPO_MAP_CACHE_DIR ($PROJECT_DIR
// relative) with a .claude/index default.
func EnsureHistoryFile(projectDir string) string {
	cacheDir := os.Getenv("REPO_MAP_CACHE_DIR")
	if cacheDir == "" {
		cacheDir = ".claude/index"
	}
	if !filepath.IsAbs(cacheDir) {
		cacheDir = filepath.Join(projectDir, cacheDir)
	}
	_ = os.MkdirAll(cacheDir, 0o755)
	return filepath.Join(cacheDir, "test_audit_history.jsonl")
}

// RecordAuditHistory appends one JSONL entry per file in files. Best-
// effort: write failures are silently dropped (matches the bash
// "warn-but-don't-block" semantics).
func RecordAuditHistory(files []string, opts SamplerOptions) error {
	if len(files) == 0 {
		return nil
	}
	if opts.HistoryFile == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(opts.HistoryFile), 0o755); err != nil {
		return err
	}
	ts := time.Now().UTC().Format(time.RFC3339)
	f, err := os.OpenFile(opts.HistoryFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	wrote := 0
	for _, name := range files {
		if name == "" {
			continue
		}
		row, marshalErr := json.Marshal(historyEntry{Timestamp: ts, File: name})
		if marshalErr != nil {
			continue
		}
		row = append(row, '\n')
		if _, writeErr := f.Write(row); writeErr == nil {
			wrote++
		}
	}
	if wrote > 0 {
		if err := PruneAuditHistory(opts); err != nil {
			return err
		}
	}
	return nil
}

// PruneAuditHistory truncates the JSONL history to the last MaxRecords
// lines. Atomic via tmp+rename, matching the bash _prune_audit_history
// pattern. MaxRecords <= 0 disables pruning.
func PruneAuditHistory(opts SamplerOptions) error {
	if opts.HistoryFile == "" {
		return nil
	}
	max := opts.MaxRecords
	if max <= 0 {
		max = 500
	}
	f, err := os.Open(opts.HistoryFile)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	var lines []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	f.Close()
	if err := sc.Err(); err != nil {
		return err
	}
	if len(lines) <= max {
		return nil
	}
	keep := lines[len(lines)-max:]
	tmp := opts.HistoryFile + ".tmp"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(out)
	for _, line := range keep {
		_, _ = w.WriteString(line)
		_ = w.WriteByte('\n')
	}
	if err := w.Flush(); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, opts.HistoryFile); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// SampleUnauditedTestFiles returns up to K test files absent from
// ac.TestFiles and ordered oldest-audited first. Files never audited get
// the epoch sentinel and sort first.
func SampleUnauditedTestFiles(ctx context.Context, ac *AuditContext, projectDir string, opts SamplerOptions) []string {
	if ac == nil {
		return nil
	}
	k := opts.K
	if k <= 0 {
		ac.SampleFiles = nil
		return nil
	}

	all := DiscoverAllTestFiles(ctx, projectDir)
	if len(all) == 0 {
		ac.SampleFiles = nil
		return nil
	}

	lastSeen := loadLastSeen(opts.HistoryFile)

	type pair struct {
		ts   string
		file string
	}
	pairs := make([]pair, 0, len(all))
	for _, f := range all {
		ts := lastSeen[f]
		if ts == "" {
			ts = epochNeverAuditedTimestamp
		}
		pairs = append(pairs, pair{ts: ts, file: f})
	}
	sort.SliceStable(pairs, func(i, j int) bool {
		if pairs[i].ts != pairs[j].ts {
			return pairs[i].ts < pairs[j].ts
		}
		return pairs[i].file < pairs[j].file
	})

	current := make(map[string]struct{}, len(ac.TestFiles))
	for _, f := range ac.TestFiles {
		current[f] = struct{}{}
	}

	var sampled []string
	for _, p := range pairs {
		if _, ok := current[p.file]; ok {
			continue
		}
		sampled = append(sampled, p.file)
		if len(sampled) >= k {
			break
		}
	}
	ac.SampleFiles = sampled
	return sampled
}

// loadLastSeen reads the JSONL history into a file → most-recent timestamp
// map. Tolerant of unparseable lines (history may include bash-written rows
// with extra whitespace).
func loadLastSeen(path string) map[string]string {
	out := map[string]string{}
	if path == "" {
		return out
	}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		raw := sc.Bytes()
		if len(raw) == 0 {
			continue
		}
		var ent historyEntry
		if err := json.Unmarshal(raw, &ent); err != nil {
			continue
		}
		if ent.File == "" || ent.Timestamp == "" {
			continue
		}
		if prev, ok := out[ent.File]; !ok || ent.Timestamp > prev {
			out[ent.File] = ent.Timestamp
		}
	}
	return out
}

// formatHistoryEntry exists for tests that want to verify the JSON shape
// without poking at private fields.
func formatHistoryEntry(ts, file string) string {
	b, _ := json.Marshal(historyEntry{Timestamp: ts, File: file})
	return string(b)
}
