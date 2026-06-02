package finalize

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/drift"
)

// ResolveAddressedNonblocking is the Go body of
// _hook_resolve_addressed_nonblocking. The bash version was
// _resolve_addressed_nonblocking_notes in lib/drift_cleanup.sh,
// deleted in m25. Its job: after the coder runs, mark `[x]` on any
// open NON_BLOCKING_LOG.md item whose body names a file the coder
// declared in CODER_SUMMARY.md's "## Files Modified" section. The
// downstream _hook_cleanup_resolved then sweeps those `[x]` items
// into the Resolved section.
//
// Without this hook, `tekhton --fix nb` is counterproductive: the
// coder can address items but nothing transitions [ ] → [x], so each
// pass sees the same un-ticked notes plus whatever new ones the
// reviewer generated. The user-reported "55 → 61 across 3 passes"
// is this hook's absence.
//
// Gate: only runs on pipeline success (ExitCode == 0). On failure
// the working state is preserved for the next run.
//
// Hook order: runs after _hook_causal_log_finalize (so the run is
// fully accounted for) and before _hook_cleanup_resolved (which
// sweeps the [x] entries this hook produces).
type ResolveAddressedNonblocking struct{}

// Name implements Hook.
func (h *ResolveAddressedNonblocking) Name() string {
	return "_hook_resolve_addressed_nonblocking"
}

// Run executes the hook. Reads CODER_SUMMARY.md's Files Modified
// list, delegates to drift.NonBlocking.ResolveByModifiedFiles. Errors
// are logged but never fail the chain (continue-on-error contract).
func (h *ResolveAddressedNonblocking) Run(_ context.Context, in *Input) error {
	if in.ExitCode != 0 {
		return nil
	}
	nbPath := nonBlockingPath(in)
	if nbPath == "" {
		return nil
	}
	files, err := readCoderSummaryFiles(in)
	if err != nil {
		fmt.Fprintf(logWriter(in), "resolve_addressed_nonblocking: read coder summary: %v\n", err)
		return nil
	}
	if len(files) == 0 {
		return nil
	}
	nb := drift.NewNonBlocking(nbPath)
	moved, err := nb.ResolveByModifiedFiles(files)
	if err != nil {
		fmt.Fprintf(logWriter(in), "resolve_addressed_nonblocking: resolve: %v\n", err)
		return nil
	}
	if moved > 0 {
		fmt.Fprintf(logWriter(in),
			"resolve_addressed_nonblocking: marked %d open item(s) resolved by modified-files heuristic\n",
			moved)
	}
	return nil
}

// coderSummaryPath resolves CODER_SUMMARY.md the same way other
// finalize hooks resolve their files: env override → relative path
// joined to ProjectDir.
func coderSummaryPath(in *Input) string {
	override := envValue(in, "CODER_SUMMARY_FILE")
	if override == "" {
		override = filepath.Join(".tekhton", "CODER_SUMMARY.md")
	}
	if filepath.IsAbs(override) {
		return override
	}
	return filepath.Join(in.ProjectDir, override)
}

// readCoderSummaryFiles extracts the list of file paths declared in
// CODER_SUMMARY.md's "## Files Modified" (or "## Files Created")
// section. The coder template uses backticked paths in markdown
// list items: "- `path/to/file.ext` — description". Returns the
// deduplicated file list. An empty list (no section, no entries,
// skeleton placeholder) is not an error — the caller treats empty
// as "no work to resolve."
func readCoderSummaryFiles(in *Input) ([]string, error) {
	path := coderSummaryPath(in)
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()

	headerRe := regexp.MustCompile(`(?i)^##\s+Files\s+(Created|Modified)\b`)
	otherHeaderRe := regexp.MustCompile(`^##\s+`)
	backtickRe := regexp.MustCompile("`([^`]+)`")
	placeholderRe := regexp.MustCompile(`(?i)^\(fill|^n/a$|^none$`)

	inSection := false
	seen := map[string]struct{}{}
	var files []string

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if headerRe.MatchString(line) {
			inSection = true
			continue
		}
		if inSection && otherHeaderRe.MatchString(line) {
			break
		}
		if !inSection {
			continue
		}
		for _, m := range backtickRe.FindAllStringSubmatch(line, -1) {
			p := strings.TrimSpace(m[1])
			if p == "" || placeholderRe.MatchString(p) {
				continue
			}
			if _, dup := seen[p]; dup {
				continue
			}
			seen[p] = struct{}{}
			files = append(files, p)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return files, nil
}
