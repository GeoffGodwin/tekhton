package detect

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Read-only filesystem helpers shared across the detect package.
// Every function here MUST be read-only. internal/detect/readonly_test.go
// scans this file (and every other non-test file in the package) for
// forbidden write APIs.

// fileExists returns true when the path refers to a regular file or any
// non-directory entry. Mirrors bash `[[ -f "$path" ]]` semantics.
func fileExists(path string) bool {
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	return !st.IsDir()
}

// readFile reads up to 1 MiB of the file at path. Returns the empty
// string on any error (including missing files) so callers can chain
// strings.Contains without nil-checking.
func readFile(path string) string {
	body, err := os.ReadFile(path) //nolint:gosec // intentional read of detection sources
	if err != nil {
		return ""
	}
	return string(body)
}

// firstMatch returns the first filesystem entry under dir matching the
// glob pattern, or the empty string if none match. Patterns are
// interpreted by filepath.Glob.
func firstMatch(dir, pattern string) string {
	matches, err := filepath.Glob(filepath.Join(dir, pattern))
	if err != nil || len(matches) == 0 {
		return ""
	}
	sort.Strings(matches)
	return matches[0]
}

// isGitRepo returns true if dir (or any ancestor up to its root) contains
// a .git directory. Mirrors `git -C dir rev-parse --git-dir` semantics
// without spawning git just to ask.
func isGitRepo(dir string) bool {
	cur := dir
	for {
		st, err := os.Stat(filepath.Join(cur, ".git"))
		if err == nil && (st.IsDir() || !st.IsDir()) {
			return true
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return false
		}
		cur = parent
	}
}

// pathHasExcludedSegment returns true when any path segment of rel
// matches one of detectExcludeDirs.
func pathHasExcludedSegment(rel string) bool {
	for _, seg := range strings.Split(rel, "/") {
		for _, ex := range detectExcludeDirs {
			if seg == ex {
				return true
			}
		}
	}
	return false
}

// depth returns the number of path segments in rel. Used to apply the
// bash `awk -F/ 'NF<=2'` ceiling.
func depth(rel string) int {
	if rel == "" {
		return 0
	}
	return strings.Count(rel, "/") + 1
}

// hasSourceFiles checks whether any file under dir (depth ≤ 2) ends in
// one of the given extensions. Mirrors lib/detect.sh::_has_source_files.
func hasSourceFiles(dir string, exts ...string) bool {
	files := findSourceFiles(dir)
	for _, name := range files {
		for _, ext := range exts {
			if strings.HasSuffix(name, "."+ext) {
				return true
			}
		}
	}
	return false
}

// walkFallback enumerates source files when git is unavailable. Mirrors
// the bash find fallback (lib/detect.sh:191-202): depth ≤ 2, excluding a
// minimal set of vendored directories.
func walkFallback(dir string) []string {
	excludes := map[string]struct{}{
		".git": {}, "node_modules": {}, "__pycache__": {}, "vendor": {},
		"third_party": {}, "build": {}, "dist": {}, "target": {},
	}
	var out []string
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(dir, path)
		if rel == "." {
			return nil
		}
		segments := strings.Split(rel, string(os.PathSeparator))
		for _, seg := range segments {
			if _, skip := excludes[seg]; skip {
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
		}
		if depth(strings.ReplaceAll(rel, string(os.PathSeparator), "/")) > 2 {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		out = append(out, strings.ReplaceAll(rel, string(os.PathSeparator), "/"))
		return nil
	})
	return out
}

// extractJSONKeys mirrors lib/detect.sh::_extract_json_keys — a grep-style
// extractor that returns the lines between any of the given section
// markers and the next closing brace. Best-effort: no JSON parsing.
func extractJSONKeys(path string, sections ...string) string {
	body := readFile(path)
	if body == "" {
		return ""
	}
	var buf strings.Builder
	lines := strings.Split(body, "\n")
	for _, section := range sections {
		inSection := false
		for _, line := range lines {
			if !inSection {
				if strings.Contains(line, section) {
					inSection = true
				}
				continue
			}
			if strings.Contains(line, "}") {
				inSection = false
				continue
			}
			buf.WriteString(line)
			buf.WriteByte('\n')
		}
	}
	return buf.String()
}

// containsDep reports whether dep appears in deps (string contains).
// Mirrors lib/detect.sh::_check_dep semantics.
func containsDep(deps, dep string) bool {
	return strings.Contains(deps, dep)
}

// reqHasLinePrefix returns true if body contains a line starting with
// prefix (case-insensitive). Mirrors `grep -qi '^prefix'`.
func reqHasLinePrefix(body, prefix string) bool {
	lower := strings.ToLower(prefix)
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(strings.ToLower(line), lower) {
			return true
		}
	}
	return false
}

// dirExists returns true when path refers to a directory.
func dirExists(path string) bool {
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	return st.IsDir()
}

// statSafe wraps os.Stat to ignore errors at call sites that only need
// IsDir-style checks.
func statSafe(path string) (os.FileInfo, error) {
	return os.Stat(path)
}

// readDirNames returns the names of entries in dir, sorted. Read-only.
func readDirNames(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	return names, nil
}

// listFilesDepth walks dir up to maxDepth (relative depth from dir) and
// returns regular file paths, excluding detectExcludeDirs. Read-only.
func listFilesDepth(dir string, maxDepth int) []string {
	var out []string
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(dir, path)
		if rel == "." {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if pathHasExcludedSegment(rel) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if depth(rel) > maxDepth {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		out = append(out, rel)
		return nil
	})
	sort.Strings(out)
	return out
}

// globMany returns matches of pattern under dir (one level deep).
func globMany(dir, pattern string) []string {
	matches, err := filepath.Glob(filepath.Join(dir, pattern))
	if err != nil {
		return nil
	}
	sort.Strings(matches)
	return matches
}
