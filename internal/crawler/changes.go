package crawler

import (
	"bytes"
	"context"
	"os/exec"
	"sort"
	"strings"
)

// Change is a single entry in the change set produced by
// DetectChangedFiles. Status is the diff-style code (A/D/M/R/...) — for
// renames the original path lives in Path and the new path lives in
// RenameTo, mirroring `git diff --name-status -R` output.
type Change struct {
	Status   string
	Path     string
	RenameTo string
}

// DetectChangedFiles returns the union of `git diff --name-status
// sinceCommit..HEAD` (committed changes) and `git status --porcelain`
// (working-tree changes), deduplicated by path. Working-tree wins on
// conflicts — matches the bash semantics where the working tree is
// concatenated AFTER the committed diff and `awk '!seen[$NF]++'` keeps
// the FIRST occurrence, but since the working-tree slice runs last and
// is processed via a map merge here, the LAST write wins, which gives
// the same effect (working tree overrides committed).
//
// Output is sorted by path for deterministic downstream behavior.
//
// Either git command failing yields an empty slice for that side — the
// bash version tolerates both via `|| true`, and full-crawl fallback in
// Rescan covers the "git unavailable" branch separately.
func DetectChangedFiles(ctx context.Context, projectDir, sinceCommit string) ([]Change, error) {
	committed := runGitDiff(ctx, projectDir, sinceCommit)
	working := runGitStatusPorcelain(ctx, projectDir)

	// Map merge — committed first so working-tree entries overwrite.
	seen := make(map[string]Change, len(committed)+len(working))
	for _, c := range committed {
		seen[c.Path] = c
	}
	for _, c := range working {
		seen[c.Path] = c
	}

	out := make([]Change, 0, len(seen))
	for _, v := range seen {
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out, nil
}

// runGitDiff returns parsed `git diff --name-status sinceCommit..HEAD`
// output. Failure (non-git, bad commit) yields nil — Rescan handles
// those preconditions in earlier branches.
func runGitDiff(ctx context.Context, projectDir, sinceCommit string) []Change {
	out, err := exec.CommandContext(ctx, "git", "-C", projectDir, "diff",
		"--name-status", sinceCommit+"..HEAD").Output()
	if err != nil {
		return nil
	}
	return parseDiffNameStatus(out)
}

// parseDiffNameStatus walks the tab-separated `git diff --name-status`
// output. Each line is `STATUS\tPATH` for A/D/M, or `R###\tOLD\tNEW`
// for renames (where ### is the similarity percentage).
func parseDiffNameStatus(out []byte) []Change {
	var changes []Change
	for _, raw := range bytes.Split(out, []byte{'\n'}) {
		if len(raw) == 0 {
			continue
		}
		parts := strings.Split(string(raw), "\t")
		if len(parts) < 2 {
			continue
		}
		status := parts[0]
		switch status[0] {
		case 'R':
			if len(parts) < 3 {
				continue
			}
			changes = append(changes, Change{
				Status:   status,
				Path:     parts[1],
				RenameTo: parts[2],
			})
		default:
			changes = append(changes, Change{
				Status: status,
				Path:   parts[1],
			})
		}
	}
	return changes
}

// runGitStatusPorcelain returns parsed `git status --porcelain` output,
// mapping the two-character porcelain status to a diff-style code per
// rescan_helpers.sh::_get_changed_files_since_scan's awk pipeline.
func runGitStatusPorcelain(ctx context.Context, projectDir string) []Change {
	out, err := exec.CommandContext(ctx, "git", "-C", projectDir, "status", "--porcelain").Output()
	if err != nil {
		return nil
	}
	return parsePorcelain(out)
}

// parsePorcelain maps `git status --porcelain` lines to Change records.
// Porcelain format is `XY filename` where XY is a two-char status code:
//   - `??` (untracked) → A
//   - `?D` or `D?` or `D ` → D
//   - `?M` or `M?` or `M ` → M
//   - `A?` → A
//   - `R?` → R
//
// Mirrors the awk script in the bash helper. Rename porcelain output
// has the form `R<sp> old -> new` — captured as Status="R", Path=old,
// RenameTo=new.
func parsePorcelain(out []byte) []Change {
	var changes []Change
	for _, raw := range bytes.Split(out, []byte{'\n'}) {
		if len(raw) < 4 {
			continue
		}
		line := string(raw)
		status := line[:2]
		// `git status --porcelain` always pads to two columns then a
		// space, so the path starts at column 3.
		path := line[3:]

		var mapped string
		switch {
		case strings.HasPrefix(status, "??"):
			mapped = "A"
		case strings.HasPrefix(status, "A"):
			mapped = "A"
		case strings.HasPrefix(status, "R"):
			mapped = "R"
		case strings.HasSuffix(status, "D") || strings.HasPrefix(status, "D"):
			mapped = "D"
		case strings.HasSuffix(status, "M") || strings.HasPrefix(status, "M"):
			mapped = "M"
		default:
			continue
		}

		if mapped == "R" {
			// Rename: `R  old -> new`. Split on " -> ".
			if idx := strings.Index(path, " -> "); idx >= 0 {
				changes = append(changes, Change{
					Status:   "R",
					Path:     path[:idx],
					RenameTo: path[idx+len(" -> "):],
				})
				continue
			}
		}
		changes = append(changes, Change{
			Status: mapped,
			Path:   path,
		})
	}
	return changes
}

// gitCommitExists ports the bash `git rev-parse --verify ${sha}^{commit}`
// check. Returns true when the commit is reachable from the current
// repo; false when the SHA has been rebased away, gc'd, or the path is
// not a git repo at all.
func gitCommitExists(ctx context.Context, projectDir, sha string) bool {
	if sha == "" {
		return false
	}
	return exec.CommandContext(ctx, "git", "-C", projectDir, "rev-parse",
		"--verify", sha+"^{commit}").Run() == nil
}

// isGitRepo ports `git -C dir rev-parse --git-dir` — true when projectDir
// is inside a git repository.
func isGitRepo(ctx context.Context, projectDir string) bool {
	return exec.CommandContext(ctx, "git", "-C", projectDir, "rev-parse", "--git-dir").Run() == nil
}
