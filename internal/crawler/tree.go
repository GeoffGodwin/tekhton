package crawler

import (
	"io/fs"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/detect"
)

// crawlExcludeDirs is the directory-exclusion list used during the tree
// walk and file listing. Sourced from the detect package so a single
// change reaches both subsystems. Mirrors _CRAWL_EXCLUDE_DIRS in
// lib/crawler.sh:42 (which already defers to _DETECT_EXCLUDE_DIRS).
func crawlExcludeDirs() []string {
	return detect.DefaultExcludeDirs()
}

// crawlDirectoryTree produces the breadth-first project tree text written
// to .claude/index/tree.txt. Prefers the GNU `tree` binary when available;
// falls back to `find` semantics otherwise. Mirrors
// lib/crawler.sh::_crawl_directory_tree.
//
// maxDepth defaults to 6 (matching the bash default). The function does
// NOT truncate; the bash version's `head -500` truncation was removed in
// M67 and the view generator handles display limits.
func crawlDirectoryTree(projectDir string, maxDepth int) string {
	if maxDepth <= 0 {
		maxDepth = 6
	}
	var output string
	if hasGNUTree() {
		output = treeBinary(projectDir, maxDepth)
	}
	if output == "" {
		// Fallback always runs when tree is unavailable OR returned empty.
		output = findBasedTree(projectDir, maxDepth)
	}
	return annotateDirectories(output)
}

func hasGNUTree() bool {
	_, err := exec.LookPath("tree")
	return err == nil
}

// treeBinary invokes the GNU `tree` binary with the same flags the bash
// crawler used: -L <depth> --noreport --dirsfirst -I <pipe-pattern>.
func treeBinary(projectDir string, maxDepth int) string {
	excludes := strings.Join(crawlExcludeDirs(), "|")
	cmd := exec.Command("tree", "-L", itoa(maxDepth),
		"--noreport", "--dirsfirst", "-I", excludes, projectDir)
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return string(out)
}

// findBasedTree mirrors lib/crawler.sh::_find_based_tree — emits the
// directory tree as `sort`-ed `find` output with the project root
// rewritten to `.`. Only directories are emitted (matches `find … -type d`).
func findBasedTree(projectDir string, maxDepth int) string {
	excludes := make(map[string]struct{})
	for _, ex := range crawlExcludeDirs() {
		excludes[ex] = struct{}{}
	}

	var dirs []string
	_ = filepath.WalkDir(projectDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !d.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(projectDir, path)
		rel = filepath.ToSlash(rel)
		if rel == "." {
			dirs = append(dirs, projectDir)
			return nil
		}
		// Exclusion mirrors bash: -not -path "*/<dir>/*" -not -name "<dir>".
		for _, seg := range strings.Split(rel, "/") {
			if _, skip := excludes[seg]; skip {
				return filepath.SkipDir
			}
		}
		// Depth limit (bash: find -maxdepth N).
		if relDepth(rel) > maxDepth {
			return filepath.SkipDir
		}
		dirs = append(dirs, path)
		return nil
	})

	sort.Strings(dirs)
	var b strings.Builder
	for _, p := range dirs {
		rewritten := strings.Replace(p, projectDir, ".", 1)
		b.WriteString(rewritten)
		b.WriteByte('\n')
	}
	// Bash printf '%s' omits the trailing newline of the last sed-stripped
	// echo; trim to match.
	return strings.TrimRight(b.String(), "\n")
}

func relDepth(rel string) int {
	if rel == "" || rel == "." {
		return 0
	}
	return strings.Count(rel, "/") + 1
}

// annotateDirectories ports the sed expressions in
// lib/crawler.sh::_annotate_directories. Each entry in annotationGroups
// is a separate `sed -e` substitution; within a group, alternations are
// tested leftmost-position then leftmost-longest (POSIX BRE semantics).
func annotateDirectories(tree string) string {
	if tree == "" {
		return tree
	}
	out := make([]string, 0, strings.Count(tree, "\n")+1)
	for _, line := range strings.Split(tree, "\n") {
		out = append(out, annotateLine(line))
	}
	return strings.Join(out, "\n")
}

// annotateLine runs each annotation group against the line, replacing
// the first match per group (no /g flag in the bash sed). Earlier groups
// may insert text that later groups see — that matches the sed -e chain.
func annotateLine(line string) string {
	for _, group := range annotationGroups {
		line = applyGroup(line, group)
	}
	return line
}

// applyGroup scans left-to-right; at each position, tries the group's
// names longest-first. The first successful match replaces and returns.
//
// Trailing-context rule (bash parity quirk): the bash sed source claims
// to match name followed by `$` OR space (`\($\| \)`), but GNU sed in
// BRE mode silently fails to recognise `$` as end-of-line when wrapped
// in a parenthesised alternation group. The effective bash behaviour is
// "match name followed by a literal space character." Preserving that
// quirk is required for byte-identical output against bash baselines;
// the intent-vs-behaviour mismatch is documented in DRIFT_LOG.md.
func applyGroup(line string, group annotationGroup) string {
	for i := 0; i < len(line); i++ {
		for _, name := range group.namesSorted {
			end := i + len(name)
			if end >= len(line) {
				// Bash sed never annotates at EOL — see comment above.
				continue
			}
			if line[i:end] != name {
				continue
			}
			if line[end] != ' ' {
				continue
			}
			return line[:end] + " [" + group.tag + "]" + line[end:]
		}
	}
	return line
}

type annotationGroup struct {
	tag         string
	namesSorted []string // longest first within the group
}

// annotationGroups mirrors the seven `-e` arms in lib/crawler.sh.
// Each group corresponds to one sed -e expression; alternations within
// a group are listed longest-first so leftmost-longest semantics hold.
var annotationGroups = []annotationGroup{
	{tag: "source", namesSorted: []string{"src"}},
	{tag: "tests", namesSorted: []string{"__tests__", "tests", "test", "spec"}},
	{tag: "documentation", namesSorted: []string{"documentation", "docs"}},
	{tag: "configuration", namesSorted: []string{".config", "config"}},
	{tag: "build/scripts", namesSorted: []string{"scripts"}},
	{tag: "CI/CD", namesSorted: []string{".github"}},
	{tag: "CI/CD", namesSorted: []string{".circleci"}},
}

// itoa is a stdlib-free int-to-string for the tree -L flag. Avoids
// pulling strconv into the tree.go file's import surface.
func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	neg := false
	if i < 0 {
		neg = true
		i = -i
	}
	var b [20]byte
	idx := len(b)
	for i > 0 {
		idx--
		b[idx] = byte('0' + i%10)
		i /= 10
	}
	if neg {
		idx--
		b[idx] = '-'
	}
	return string(b[idx:])
}
