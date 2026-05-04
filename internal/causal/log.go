package causal

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// Log is the writer-side handle for a CAUSAL_LOG.jsonl file. The bash writer
// kept its per-stage counter on disk because subshell `$()` capture would
// otherwise lose in-memory state. The Go writer keeps the counter in-process
// (atomic.Int64 per stage) and seeds it by scanning the existing log file at
// Open time — this lets a fresh `tekhton causal emit` invocation pick up
// from where the previous run left off without touching a sidecar file.
type Log struct {
	path  string
	cap   int
	runID string

	mu    sync.Mutex
	count int

	seqMu sync.Mutex
	seq   map[string]*atomic.Int64
}

// Open prepares a Log writer at path. The directory is created if missing.
// If the file already exists, its line count and per-stage seq numbers are
// loaded so subsequent Emits continue the sequence (resume-friendly).
//
// cap is the maximum number of events retained in path before eviction
// fires; matches the prior bash CAUSAL_LOG_MAX_EVENTS semantics. cap <= 0
// disables eviction.
func Open(path string, cap int, runID string) (*Log, error) {
	if path == "" {
		return nil, errors.New("causal: empty log path")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("causal: mkdir log dir: %w", err)
	}
	// Ensure runs/ archive directory alongside the log.
	_ = os.MkdirAll(filepath.Join(filepath.Dir(path), "runs"), 0o755)

	l := &Log{
		path:  path,
		cap:   cap,
		runID: runID,
		seq:   make(map[string]*atomic.Int64),
	}
	if err := l.seedFromExisting(); err != nil {
		return nil, err
	}
	return l, nil
}

// seedFromExisting scans the on-disk log to populate l.count and l.seq so
// resumed runs continue monotonic per-stage IDs without colliding with
// previously-written events.
func (l *Log) seedFromExisting() error {
	f, err := os.Open(l.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("causal: open existing log: %w", err)
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	// Allow long lines — the detail field can be long.
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		l.count++
		stage, n := parseStageAndSeq(line)
		if stage == "" || n <= 0 {
			continue
		}
		l.bumpSeqAtLeast(stage, n)
	}
	return sc.Err()
}

// parseStageAndSeq extracts stage and seq from an event line's "id":"<stage>.<seq>".
// We do a single-pass byte scan rather than json.Unmarshal so resume seeding
// is fast even for 2000-event logs.
func parseStageAndSeq(line []byte) (string, int64) {
	const key = `"id":"`
	idx := strings.Index(string(line), key)
	if idx < 0 {
		return "", 0
	}
	rest := string(line[idx+len(key):])
	end := strings.IndexByte(rest, '"')
	if end <= 0 {
		return "", 0
	}
	idStr := rest[:end]
	dot := strings.LastIndexByte(idStr, '.')
	if dot <= 0 || dot == len(idStr)-1 {
		return "", 0
	}
	stage := idStr[:dot]
	var seq int64
	for i := dot + 1; i < len(idStr); i++ {
		c := idStr[i]
		if c < '0' || c > '9' {
			return "", 0
		}
		seq = seq*10 + int64(c-'0')
	}
	return stage, seq
}

func (l *Log) bumpSeqAtLeast(stage string, n int64) {
	l.seqMu.Lock()
	c, ok := l.seq[stage]
	if !ok {
		c = &atomic.Int64{}
		l.seq[stage] = c
	}
	l.seqMu.Unlock()
	for {
		cur := c.Load()
		if cur >= n {
			return
		}
		if c.CompareAndSwap(cur, n) {
			return
		}
	}
}

func (l *Log) nextSeq(stage string) int64 {
	l.seqMu.Lock()
	c, ok := l.seq[stage]
	if !ok {
		c = &atomic.Int64{}
		l.seq[stage] = c
	}
	l.seqMu.Unlock()
	return c.Add(1)
}

// EmitInput is the per-call input bundle for Emit. Keeping this as a struct
// rather than a long parameter list keeps the CLI wiring readable.
type EmitInput struct {
	Stage     string
	Type      string
	Detail    string
	Milestone string
	CausedBy  []string
	Verdict   json.RawMessage
	Context   json.RawMessage
}

// Emit appends one event line to the log file and returns the assigned
// event ID. Eviction fires synchronously when count > cap to bound the file
// size at runtime — the bash writer behaved the same way.
func (l *Log) Emit(in EmitInput) (string, error) {
	if in.Stage == "" {
		return "", errors.New("causal: emit: empty stage")
	}
	if in.Type == "" {
		return "", errors.New("causal: emit: empty type")
	}

	seq := l.nextSeq(in.Stage)
	id := FormatEventID(in.Stage, seq)

	ev := &proto.CausalEventV1{
		Proto:     proto.CausalProtoV1,
		ID:        id,
		Ts:        nowRFC3339(),
		RunID:     l.runID,
		Milestone: in.Milestone,
		Type:      in.Type,
		Stage:     in.Stage,
		Detail:    in.Detail,
		CausedBy:  in.CausedBy,
		Verdict:   in.Verdict,
		Context:   in.Context,
	}
	line := append(ev.MarshalLine(), '\n')

	l.mu.Lock()
	defer l.mu.Unlock()
	if err := appendBytes(l.path, line); err != nil {
		return "", err
	}
	l.count++
	if l.cap > 0 && l.count > l.cap {
		if err := l.evictLocked(); err != nil {
			return id, err
		}
	}
	return id, nil
}

// appendBytes writes data to path with O_APPEND|O_CREATE semantics. We open
// per-call rather than holding a long-lived handle so concurrent CLI
// invocations from bash don't share file state — the OS append guarantees
// atomicity for writes ≤ PIPE_BUF, which our lines comfortably are.
func appendBytes(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("causal: open log for append: %w", err)
	}
	defer f.Close()
	_, err = f.Write(data)
	return err
}

// evictLocked rewrites the log file in place, retaining the most recent
// l.cap lines. Caller must hold l.mu.
func (l *Log) evictLocked() error {
	f, err := os.Open(l.path)
	if err != nil {
		return fmt.Errorf("causal: evict open: %w", err)
	}
	lines := make([]string, 0, l.cap*2)
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	f.Close()
	if err := sc.Err(); err != nil {
		return fmt.Errorf("causal: evict scan: %w", err)
	}
	if len(lines) <= l.cap {
		l.count = len(lines)
		return nil
	}
	keep := lines[len(lines)-l.cap:]
	tmp := l.path + ".tmp"
	out, err := os.Create(tmp)
	if err != nil {
		return fmt.Errorf("causal: evict create tmp: %w", err)
	}
	w := bufio.NewWriter(out)
	for _, line := range keep {
		_, _ = w.WriteString(line)
		_ = w.WriteByte('\n')
	}
	if err := w.Flush(); err != nil {
		out.Close()
		return fmt.Errorf("causal: evict flush: %w", err)
	}
	if err := out.Close(); err != nil {
		return fmt.Errorf("causal: evict close tmp: %w", err)
	}
	if err := os.Rename(tmp, l.path); err != nil {
		return fmt.Errorf("causal: evict rename: %w", err)
	}
	l.count = len(keep)
	return nil
}

// Archive copies the current log to runs/CAUSAL_LOG_<runID>.jsonl alongside
// the log file, then prunes archives beyond retention. Matching the bash
// behavior: the live log is not truncated by archive — caller decides.
func (l *Log) Archive(retention int) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if _, err := os.Stat(l.path); err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	runsDir := filepath.Join(filepath.Dir(l.path), "runs")
	if err := os.MkdirAll(runsDir, 0o755); err != nil {
		return fmt.Errorf("causal: archive mkdir: %w", err)
	}
	dst := filepath.Join(runsDir, fmt.Sprintf("CAUSAL_LOG_%s.jsonl", l.runID))
	if err := copyFile(l.path, dst); err != nil {
		return err
	}
	return pruneArchives(runsDir, retention)
}

// Close is currently a no-op — Log holds no long-lived OS handles. Exposed
// so future implementations can swap to a buffered writer without breaking
// callers.
func (l *Log) Close() error { return nil }

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("causal: archive open src: %w", err)
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return fmt.Errorf("causal: archive create dst: %w", err)
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return fmt.Errorf("causal: archive copy: %w", err)
	}
	return out.Close()
}

// pruneArchives removes archived logs beyond retention, keeping the newest
// `retention` files. retention <= 0 disables pruning.
func pruneArchives(runsDir string, retention int) error {
	if retention <= 0 {
		return nil
	}
	entries, err := os.ReadDir(runsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	type fileInfo struct {
		name string
		mod  int64
	}
	var archives []fileInfo
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, "CAUSAL_LOG_") || !strings.HasSuffix(name, ".jsonl") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		archives = append(archives, fileInfo{name: name, mod: info.ModTime().UnixNano()})
	}
	if len(archives) <= retention {
		return nil
	}
	sort.Slice(archives, func(i, j int) bool { return archives[i].mod > archives[j].mod })
	for _, a := range archives[retention:] {
		_ = os.Remove(filepath.Join(runsDir, a.name))
	}
	return nil
}

// Path returns the configured log path (used by status output).
func (l *Log) Path() string { return l.path }

// Count returns the in-memory event count for this Log instance. Useful for
// tests; CLI status reads from the file directly to avoid stale state.
func (l *Log) Count() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.count
}
