package docs

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/stages/staglog"
)

// shouldSkip returns true when the docs stage can short-circuit past the
// agent invocation. Mirrors docs_agent_should_skip in lib/docs_agent.sh:
//
//   - no changed files → skip (nothing to document)
//   - no CLAUDE.md Documentation Responsibilities section → run
//     (false-negative skip is worse than false-positive run; the bash
//     comment at lib/docs_agent.sh:23 makes this explicit)
//   - changed files don't intersect surface patterns → skip
//
// The projectDir argument is the working directory for `git diff` lookups;
// rulesFile is the path (typically CLAUDE.md) to scan for the surface section.
func shouldSkip(projectDir, rulesFile string, log staglog.Logger) bool {
	changed, err := changedFiles(projectDir)
	if err != nil || len(changed) == 0 {
		log.Info("[docs] No changed files detected. Skipping docs agent.")
		return true
	}

	patterns := extractPublicSurface(projectDir, rulesFile)
	if len(patterns) == 0 {
		log.Info("[docs] No Documentation Responsibilities section in CLAUDE.md. Running agent.")
		return false
	}

	if filesMatchSurface(changed, patterns) {
		return false
	}
	log.Info("[docs] No public-surface files changed. Skipping docs agent.")
	return true
}

// changedFiles returns the set of working-tree files touched since HEAD.
// Falls back to the staged diff when the unstaged diff is empty so a fully-
// committed change set (the typical mid-pipeline state right after the coder
// commits) still surfaces. Mirrors the two-arm pattern in
// lib/docs_agent.sh::docs_agent_should_skip.
func changedFiles(projectDir string) ([]string, error) {
	out, err := runGit(projectDir, "diff", "--name-only", "HEAD")
	if err == nil && len(strings.TrimSpace(out)) == 0 {
		out, err = runGit(projectDir, "diff", "--cached", "--name-only")
	}
	if err != nil {
		return nil, err
	}
	var files []string
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		files = append(files, line)
	}
	return files, nil
}

func runGit(workdir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = workdir
	out, err := cmd.Output()
	return string(out), err
}

// extractDocResponsibilities reads the Documentation Responsibilities section
// (H2 heading, any "Documentation Responsibilities" suffix) from a CLAUDE.md-
// style file. Returns the raw section text (lines between the header and the
// next H2), or empty when the section is absent. Ported from
// lib/docs_agent.sh::_docs_extract_doc_responsibilities.
func extractDocResponsibilities(raw string) string {
	headerRE := regexp.MustCompile(`(?i)^##.*documentation\s+responsibilities`)
	lines := strings.Split(raw, "\n")
	inSection := false
	var out []string
	for _, ln := range lines {
		if !inSection {
			if headerRE.MatchString(ln) {
				inSection = true
			}
			continue
		}
		// Stop at the next H2 that is NOT another doc-responsibilities header.
		// Mirrors the sed delete-pattern `/^## [^D]/d`.
		if strings.HasPrefix(ln, "## ") && !headerRE.MatchString(ln) {
			break
		}
		out = append(out, ln)
	}
	return strings.Join(out, "\n")
}

// surfaceExtRE matches `*.ext` patterns inside the surface section.
var surfaceExtRE = regexp.MustCompile(`\*\.[a-zA-Z0-9]+`)

// surfacePathRE matches explicit doc-style paths (README.md, docs/foo.md, …).
var surfacePathRE = regexp.MustCompile(`[a-zA-Z0-9_./]+\.(md|txt|rst|adoc)`)

// surfaceDirRE matches directory references (docs/, src/, …). Conservative —
// only a-zA-Z0-9 _ - allowed in the slug, matching the bash grep.
var surfaceDirRE = regexp.MustCompile(`[a-zA-Z0-9_-]+/`)

// extractPublicSurface reads CLAUDE.md (or PROJECT_RULES_FILE), finds the
// Documentation Responsibilities section, and extracts public-surface
// indicators as glob-style patterns. Always seeds README.md and the
// DOCS_README_FILE / DOCS_DIRS env values so the surface is non-empty even
// when the section names nothing concrete. Ported from
// lib/docs_agent.sh::_docs_extract_public_surface.
func extractPublicSurface(projectDir, rulesFile string) []string {
	if rulesFile == "" {
		rulesFile = "CLAUDE.md"
	}
	path := rulesFile
	if !filepath.IsAbs(path) {
		path = filepath.Join(projectDir, rulesFile)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	section := extractDocResponsibilities(string(raw))
	if strings.TrimSpace(section) == "" {
		return nil
	}

	seen := map[string]struct{}{}
	add := func(s string) {
		s = strings.TrimSpace(s)
		if s == "" {
			return
		}
		seen[s] = struct{}{}
	}
	for _, m := range surfaceExtRE.FindAllString(section, -1) {
		add(m)
	}
	for _, m := range surfacePathRE.FindAllString(section, -1) {
		add(m)
	}
	for _, m := range surfaceDirRE.FindAllString(section, -1) {
		add(m)
	}
	// Bash side unconditionally seeds README.md, DOCS_README_FILE, DOCS_DIRS.
	add("README.md")
	if v := os.Getenv("DOCS_README_FILE"); v != "" {
		add(v)
	} else {
		add("README.md")
	}
	if v := os.Getenv("DOCS_DIRS"); v != "" {
		add(v)
	} else {
		add("docs/")
	}

	out := make([]string, 0, len(seen))
	for s := range seen {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}

// filesMatchSurface returns true when at least one entry in files matches a
// pattern in patterns. Glob patterns containing "*" are translated to regex;
// patterns without "*" are literal substring matches. Ported from
// lib/docs_agent.sh::_docs_changed_files_match_surface.
func filesMatchSurface(files, patterns []string) bool {
	for _, pat := range patterns {
		if pat == "" {
			continue
		}
		if strings.Contains(pat, "*") {
			re, err := globToRegexp(pat)
			if err != nil {
				continue
			}
			for _, f := range files {
				if re.MatchString(f) {
					return true
				}
			}
			continue
		}
		for _, f := range files {
			if strings.Contains(f, pat) {
				return true
			}
		}
	}
	return false
}

// globToRegexp converts a shell-style glob (only * is recognised, mirroring
// the bash sed transform `s/\./\\./g; s/\*/.*/g`) to a compiled regexp.
func globToRegexp(glob string) (*regexp.Regexp, error) {
	var b strings.Builder
	for _, r := range glob {
		switch r {
		case '.':
			b.WriteString(`\.`)
		case '*':
			b.WriteString(`.*`)
		default:
			b.WriteRune(r)
		}
	}
	return regexp.Compile(b.String())
}
