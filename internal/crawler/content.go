package crawler

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"
)

// Sample is one entry in samples/manifest.json. Original is the
// repo-relative source path; Stored is the flattened filename written
// under .claude/index/samples/; Content is the (possibly truncated)
// sampled body; Chars is the rune count of Content (matches the
// manifest's `chars` field — bash uses ${#var} which is rune-aware).
type Sample struct {
	Original string `json:"original"`
	Stored   string `json:"stored"`
	Content  string `json:"-"`
	Chars    int    `json:"chars"`
}

// sampleFiles picks high-priority project files in the order README →
// entry points → primary manifest → architecture docs → first test →
// first source, then samples each file within the supplied char budget.
// Mirrors lib/crawler_content.sh::_emit_sampled_files.
//
// Bash parity invariants preserved here:
//   - Sample content has ALL trailing newlines stripped (mirrors $()).
//   - Budget arithmetic is in UTF-8 character counts, not bytes
//     (mirrors `${#var}` which respects LC_*).
//   - Files written to disk hold the byte-for-byte content (no
//     re-encoding) but `chars` in the manifest is the rune count.
//
// designFile is the optional DESIGN.md path from $DESIGN_FILE (mirrors
// the bash env var); pass "" when unset.
func sampleFiles(projectDir string, files []string, budget int, designFile string) []Sample {
	candidates := buildSampleCandidates(files, designFile)
	used := 0
	var out []Sample
	for _, rel := range candidates {
		if used >= budget {
			break
		}
		full := filepath.Join(projectDir, rel)
		st, err := os.Stat(full)
		if err != nil || st.IsDir() {
			continue
		}
		if isBinary(full) {
			continue
		}
		remaining := budget - used
		content := readSampled(full, remaining)
		if content == "" {
			continue
		}
		stored := strings.ReplaceAll(rel, "/", "__") + ".txt"
		runeCount := utf8.RuneCountInString(content)
		out = append(out, Sample{
			Original: rel,
			Stored:   stored,
			Content:  content,
			Chars:    runeCount,
		})
		// Bash accounting: used += content_size + len(filename) + 20.
		// ${#filename} is also a rune count.
		used += runeCount + utf8.RuneCountInString(rel) + 20
	}
	return out
}

// buildSampleCandidates produces the priority-ordered candidate list,
// retaining only files actually present in the supplied file list (so
// non-existent README.rst etc. are silently dropped). The order matches
// the bash _add_candidate sequence verbatim.
func buildSampleCandidates(files []string, designFile string) []string {
	present := make(map[string]struct{}, len(files))
	for _, f := range files {
		present[f] = struct{}{}
	}

	var out []string
	add := func(names ...string) {
		for _, n := range names {
			if n == "" {
				continue
			}
			if _, ok := present[n]; !ok {
				continue
			}
			out = append(out, n)
		}
	}

	// Priority 1: README.
	add("README.md", "README.rst", "README", "README.txt")
	// Priority 2: entry points.
	add(
		"main.py", "app.py", "index.ts", "index.js",
		"main.ts", "main.go", "main.rs", "lib.rs",
		"src/main.rs", "src/lib.rs", "src/index.ts",
		"src/index.js", "src/app.ts", "src/app.js",
		"src/main.py", "cmd/main.go",
	)
	// Priority 3: primary manifest.
	add(
		"package.json", "Cargo.toml", "pyproject.toml",
		"go.mod", "Gemfile", "pubspec.yaml", "composer.json",
	)
	// Priority 4: architecture docs.
	add("ARCHITECTURE.md", "CONTRIBUTING.md", designFile,
		"docs/ARCHITECTURE.md", "docs/design.md")
	// Priority 5: first matching test file.
	if t := firstMatchRegex(files, rxTestFile); t != "" {
		out = append(out, t)
	}
	// Priority 6: first matching source file under src/.
	if s := firstMatchRegex(files, rxSrcFile); s != "" {
		out = append(out, s)
	}
	return out
}

// rxTestFile ports `\.(test|spec)\.[^.]+$|_test\.[^.]+$`.
var rxTestFile = regexp.MustCompile(`\.(test|spec)\.[^.]+$|_test\.[^.]+$`)

// rxSrcFile ports `^src/.*\.(py|ts|js|go|rs|java|rb)$`.
var rxSrcFile = regexp.MustCompile(`^src/.*\.(py|ts|js|go|rs|java|rb)$`)

func firstMatchRegex(files []string, rx *regexp.Regexp) string {
	for _, f := range files {
		if rx.MatchString(f) {
			return f
		}
	}
	return ""
}

// binaryExtensions ports the case-statement fallback in
// lib/crawler_content.sh::_is_binary_file.
var binaryExtensions = map[string]struct{}{
	"png": {}, "jpg": {}, "jpeg": {}, "gif": {}, "bmp": {}, "ico": {}, "svg": {},
	"woff": {}, "woff2": {}, "ttf": {}, "eot": {}, "otf": {},
	"mp3": {}, "mp4": {}, "avi": {}, "mov": {}, "webm": {}, "ogg": {}, "wav": {}, "flac": {},
	"zip": {}, "gz": {}, "tar": {}, "bz2": {}, "7z": {}, "rar": {}, "xz": {},
	"pdf": {}, "doc": {}, "docx": {}, "xls": {}, "xlsx": {}, "ppt": {}, "pptx": {},
	"exe": {}, "dll": {}, "so": {}, "dylib": {}, "o": {}, "a": {}, "class": {}, "pyc": {}, "pyo": {},
	"db": {}, "sqlite": {}, "sqlite3": {},
}

// isBinary checks whether a file is binary. First tries the null-byte
// heuristic on the first 512 bytes (matching bash `head -c 512 | grep -qP '\x00'`),
// then falls back to the extension allowlist.
func isBinary(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	buf := make([]byte, 512)
	n, _ := f.Read(buf)
	if bytes.IndexByte(buf[:n], 0) >= 0 {
		return true
	}
	// Extension fallback.
	ext := strings.TrimPrefix(filepath.Ext(path), ".")
	if ext == "" {
		return false
	}
	_, ok := binaryExtensions[strings.ToLower(ext)]
	return ok
}

// readSampled returns the file content with line-budget awareness.
// Mirrors lib/crawler_content.sh::_read_sampled_file:
//   - >1000 lines: first 50 + omission marker + last 20.
//   - ≤1000 lines: full content.
//   - All trailing newlines stripped (mirrors bash `$(cat …)` semantics).
//   - Truncate to charBudget (character count) at the last newline
//     boundary, appending "\n... (truncated to fit budget)".
func readSampled(path string, charBudget int) string {
	data, err := os.ReadFile(path) //nolint:gosec // intentional read of sampled file
	if err != nil {
		return ""
	}
	lines := bytes.Count(data, []byte{'\n'})
	var content string
	if lines > 1000 {
		all := strings.Split(string(data), "\n")
		omitted := lines - 70
		head := strings.Join(all[:50], "\n")
		tail := strings.Join(all[len(all)-20:], "\n")
		content = head + "\n" + "... (" + itoa(omitted) + " lines omitted)" + "\n" + tail
	} else {
		content = string(data)
	}

	// Bash command substitution `$(cat …)` strips ALL trailing newlines
	// before the value lands in the variable. Mirror that here so the
	// on-disk sample file and the ${#content} char count match bash.
	content = strings.TrimRight(content, "\n")

	// Character-count truncation (bash `${content:0:N}` uses LC_*-aware
	// char indexing; with a UTF-8 locale that means rune count).
	if utf8.RuneCountInString(content) > charBudget {
		content = runeSlice(content, charBudget)
		if idx := strings.LastIndexByte(content, '\n'); idx >= 0 {
			content = content[:idx]
		}
		content += "\n... (truncated to fit budget)"
	}
	return content
}

// runeSlice returns the first n runes of s as a string. Used to mirror
// bash `${var:0:N}` substring semantics under a UTF-8 locale.
func runeSlice(s string, n int) string {
	if n <= 0 {
		return ""
	}
	count := 0
	for i := range s {
		if count == n {
			return s[:i]
		}
		count++
	}
	return s
}
