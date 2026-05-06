package supervisor

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/fsnotify/fsnotify"
)

// ActivityWatcher reports whether files inside a project tree have been
// modified since a caller-supplied timestamp. It is the m09 replacement for
// V3's `find <dir> -newer <ref>` polling: when an agent is silently writing
// to disk while emitting no stdout, the activity timer would otherwise kill
// it. The watcher gives the timer a way to override that decision.
//
// Two modes:
//
//   - fsnotify mode: a recursive set of inotify/kqueue/ReadDirectoryChangesW
//     watches reports each modify event. HadActivitySince() reads an atomic
//     timestamp updated by the event loop. Cost: one goroutine, one FD per
//     watched directory. We exclude .git/, the supervisor's own writes, and
//     well-known dependency caches to keep watch counts bounded.
//
//   - fallback mode: when fsnotify init fails (rare; some FUSE mounts and
//     certain WSL configs lack inotify), HadActivitySince() walks the tree
//     and stats mtimes. Slower but correct. A causal event flags the mode
//     at construction time so operators can investigate.
//
// The watcher is safe for concurrent reads. Close stops the event loop.
type ActivityWatcher struct {
	dir       string
	notifier  *fsnotify.Watcher
	lastEvent atomic.Int64 // unix nano of most recent qualifying event
	fallback  bool

	once     sync.Once
	closeCh  chan struct{}
	closeErr error
}

// excludedSegments are path segments anywhere in the relative file path that
// disqualify the file from triggering activity. The supervisor writes to
// `.tekhton/CAUSAL_LOG.jsonl` constantly; if we counted those writes the
// timer would never fire. Build-output and dependency caches are excluded
// for cost reasons (they thrash millions of times during normal builds).
var excludedSegments = []string{
	".git",
	".tekhton",
	".cache",
	"node_modules",
	"vendor",
	"bin",
	"dist",
	"build",
	".idea",
	".vscode",
}

// NewActivityWatcher constructs a watcher rooted at dir. Returns a non-nil
// watcher even when fsnotify init fails — in that case the fallback walker
// is used. The only error path is a missing or unreadable root directory;
// the caller is expected to guard against that earlier (req.WorkingDir is
// validated upstream) but we surface the error anyway for diagnosis.
func NewActivityWatcher(dir string) (*ActivityWatcher, error) {
	if dir == "" {
		return nil, errors.New("activity watcher: empty dir")
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	st, err := os.Stat(abs)
	if err != nil {
		return nil, err
	}
	if !st.IsDir() {
		return nil, errors.New("activity watcher: not a directory")
	}

	w := &ActivityWatcher{dir: abs, closeCh: make(chan struct{})}
	w.lastEvent.Store(0)

	notifier, nerr := fsnotify.NewWatcher()
	if nerr != nil {
		// Fallback path. Not fatal — V3 polling stays correct, just slower.
		w.fallback = true
		return w, nil
	}
	if err := w.addRecursive(notifier, abs); err != nil {
		notifier.Close()
		w.fallback = true
		return w, nil
	}
	w.notifier = notifier
	go w.loop()
	return w, nil
}

// addRecursive walks dir and registers a watch on every directory not in
// excludedSegments. Files don't need to be added directly — inotify reports
// events on the parent dir for create/modify/delete of contained files.
func (w *ActivityWatcher) addRecursive(notifier *fsnotify.Watcher, root string) error {
	return filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			// Permission denied or similar — skip silently. fsnotify will
			// still see events for siblings and the parent.
			return nil
		}
		if !d.IsDir() {
			return nil
		}
		if path != root && isExcluded(path, root) {
			return filepath.SkipDir
		}
		_ = notifier.Add(path)
		return nil
	})
}

// loop drains the fsnotify event channel and stamps lastEvent for any event
// that survives the exclude filter. Errors from the watcher are swallowed —
// fsnotify reports queue overflow as ErrEventOverflow which the V3 poller
// would also miss; we don't escalate.
func (w *ActivityWatcher) loop() {
	for {
		select {
		case <-w.closeCh:
			return
		case ev, ok := <-w.notifier.Events:
			if !ok {
				return
			}
			if !qualifiesEvent(ev) {
				continue
			}
			if isExcluded(ev.Name, w.dir) {
				continue
			}
			w.lastEvent.Store(time.Now().UnixNano())

			// New directories created after we started watching need to be
			// added to the watcher so events under them are also seen.
			if ev.Op&fsnotify.Create != 0 {
				if st, err := os.Stat(ev.Name); err == nil && st.IsDir() {
					_ = w.notifier.Add(ev.Name)
				}
			}
		case _, ok := <-w.notifier.Errors:
			if !ok {
				return
			}
		}
	}
}

// qualifiesEvent filters out noise events (CHMOD-only) and keeps anything
// that represents real file modification. Removes are counted because an
// agent writing-and-deleting temp files is still doing useful work.
func qualifiesEvent(ev fsnotify.Event) bool {
	if ev.Op == fsnotify.Chmod {
		return false
	}
	return ev.Op&(fsnotify.Write|fsnotify.Create|fsnotify.Remove|fsnotify.Rename) != 0
}

// isExcluded returns true when any path segment under root matches an entry
// in excludedSegments. Path separators are normalized to forward-slash for
// cross-platform comparison.
func isExcluded(path, root string) bool {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	rel = filepath.ToSlash(rel)
	if rel == "." || rel == "" {
		return false
	}
	parts := strings.Split(rel, "/")
	for _, p := range parts {
		for _, ex := range excludedSegments {
			if p == ex {
				return true
			}
		}
	}
	return false
}

// HadActivitySince reports whether the watched tree saw a qualifying
// modification after t. In fsnotify mode this is an O(1) atomic read; in
// fallback mode it walks the tree and stats mtimes (V3 parity). The walk
// stops on the first hit so the cost stays bounded even on large repos.
func (w *ActivityWatcher) HadActivitySince(t time.Time) bool {
	if w == nil {
		return false
	}
	if !w.fallback {
		ns := w.lastEvent.Load()
		if ns == 0 {
			return false
		}
		return time.Unix(0, ns).After(t)
	}
	return w.fallbackHadActivitySince(t)
}

// fallbackHadActivitySince is the V3 `find -newer` equivalent. Walks dir,
// stats each file, returns true at the first mtime > t. Excluded segments
// are pruned at the directory level so the walk doesn't descend into .git/
// or node_modules.
func (w *ActivityWatcher) fallbackHadActivitySince(t time.Time) bool {
	hit := false
	_ = filepath.WalkDir(w.dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if path != w.dir && isExcluded(path, w.dir) {
				return filepath.SkipDir
			}
			return nil
		}
		if isExcluded(path, w.dir) {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		if info.ModTime().After(t) {
			hit = true
			return filepath.SkipAll
		}
		return nil
	})
	return hit
}

// IsFallback exposes the mode for diagnostics. Tests and the run loop both
// emit a one-shot causal event when fallback is engaged so operators know
// the watcher is paying the polling cost.
func (w *ActivityWatcher) IsFallback() bool {
	if w == nil {
		return false
	}
	return w.fallback
}

// Close stops the event loop and releases watcher resources. Safe to call
// multiple times — subsequent calls are no-ops. Returns the underlying
// fsnotify error (usually nil).
func (w *ActivityWatcher) Close() error {
	if w == nil {
		return nil
	}
	w.once.Do(func() {
		close(w.closeCh)
		if w.notifier != nil {
			w.closeErr = w.notifier.Close()
		}
	})
	return w.closeErr
}
