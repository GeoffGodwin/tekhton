package dag

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/manifest"
)

// Migration sentinels.
var (
	// ErrMigrateAlreadyDone is returned when MANIFEST.cfg already exists in
	// the milestone directory. The bash migrate_inline_milestones returned 0
	// in this case ("idempotent skip"); the Go side returns this sentinel so
	// callers can distinguish a real success from a no-op.
	ErrMigrateAlreadyDone = errors.New("dag: manifest already exists")
	// ErrNoMilestonesFound — CLAUDE.md had no parseable Milestone headings.
	ErrNoMilestonesFound = errors.New("dag: no inline milestones found")
)

// MigrateOptions configures Migrate.
type MigrateOptions struct {
	// ClaudeMD is the path to the source CLAUDE.md.
	ClaudeMD string
	// MilestoneDir is the destination directory for milestone files
	// (typically <project>/.claude/milestones).
	MilestoneDir string
	// ManifestName overrides the default "MANIFEST.cfg".
	ManifestName string
}

// Migrate extracts inline milestones from a CLAUDE.md into individual files in
// the milestone directory and writes a fresh MANIFEST.cfg. Idempotent: returns
// ErrMigrateAlreadyDone when the manifest already exists.
//
// Migration steps mirror lib/milestone_dag_migrate.sh::migrate_inline_milestones:
//  1. Bail if MANIFEST.cfg already exists.
//  2. parseInlineMilestones() walks the CLAUDE.md in one pass, recording each
//     milestone's number, title, [DONE] flag, and full block.
//  3. For each milestone: slugify title, build filename "{id}-{slug}.md",
//     infer dependencies (explicit "depends on Milestone N" or fallback to
//     sequential).
//  4. Write each milestone's block to its file (text + content from CLAUDE.md).
//  5. Write MANIFEST.cfg atomically (tmpfile + rename).
//
// Returns the number of milestones migrated on success.
func Migrate(opts MigrateOptions) (int, error) {
	if opts.ClaudeMD == "" {
		return 0, errors.New("dag: ClaudeMD path required")
	}
	if opts.MilestoneDir == "" {
		return 0, errors.New("dag: MilestoneDir required")
	}
	manifestName := opts.ManifestName
	if manifestName == "" {
		manifestName = "MANIFEST.cfg"
	}
	manifestPath := filepath.Join(opts.MilestoneDir, manifestName)

	if _, err := os.Stat(manifestPath); err == nil {
		return 0, ErrMigrateAlreadyDone
	}

	if _, err := os.Stat(opts.ClaudeMD); err != nil {
		return 0, fmt.Errorf("dag: %s not found: %w", opts.ClaudeMD, err)
	}

	parsed, err := parseInlineMilestones(opts.ClaudeMD)
	if err != nil {
		return 0, err
	}
	if len(parsed) == 0 {
		return 0, ErrNoMilestonesFound
	}

	if err := os.MkdirAll(opts.MilestoneDir, 0o755); err != nil {
		return 0, fmt.Errorf("dag: mkdir milestone dir: %w", err)
	}

	m := &manifest.Manifest{Path: manifestPath}
	for i, p := range parsed {
		id := numberToID(p.number)
		slug := slugify(p.title)
		filename := id + "-" + slug + ".md"

		status := StatusPending
		if p.done {
			status = StatusDone
		}

		deps := inferDependencies(p.block, p.number, parsed, i)

		body := p.block
		if strings.TrimSpace(body) == "" {
			body = fmt.Sprintf("#### Milestone %s: %s\n\n(Migrated from %s — original content not extractable)",
				p.number, p.title, opts.ClaudeMD)
		}

		filePath := filepath.Join(opts.MilestoneDir, filename)
		if err := os.WriteFile(filePath, []byte(body+"\n"), 0o644); err != nil {
			return 0, fmt.Errorf("dag: write %s: %w", filePath, err)
		}

		m.Entries = append(m.Entries, &manifest.Entry{
			ID:      id,
			Title:   p.title,
			Status:  status,
			Depends: deps,
			File:    filename,
		})
	}

	if err := m.Save(); err != nil {
		return 0, fmt.Errorf("dag: save manifest: %w", err)
	}
	return len(parsed), nil
}

// parsedMilestone is one milestone heading + its block extracted from CLAUDE.md.
type parsedMilestone struct {
	number string
	title  string
	done   bool
	block  string
}

// milestoneHeading matches: optional leading whitespace, 1-5 #s, optional
// [DONE] marker, "Milestone N(.M)*", separator, title.
var milestoneHeadingRE = regexp.MustCompile(`^[[:space:]]*(#{1,5})[[:space:]]*(\[DONE\][[:space:]]*)?[Mm]ilestone[[:space:]]+([0-9]+(?:\.[0-9]+)*)[[:space:]]*[:.\-—][[:space:]]*(.*)$`)

// generalHeadingRE matches any markdown heading (1-5 #s).
var generalHeadingRE = regexp.MustCompile(`^(#{1,5})[[:space:]]+`)

// parseInlineMilestones walks claudeMD and returns one entry per milestone
// heading found. The block field is the full text from the milestone heading
// up to (but not including) the next heading at the same or higher level.
func parseInlineMilestones(claudeMD string) ([]parsedMilestone, error) {
	f, err := os.Open(claudeMD)
	if err != nil {
		return nil, fmt.Errorf("dag: open: %w", err)
	}
	defer f.Close()

	var (
		out     []parsedMilestone
		current *parsedMilestone
		curLvl  int
		buf     strings.Builder
	)

	flush := func() {
		if current == nil {
			return
		}
		current.block = strings.TrimRight(buf.String(), "\n")
		out = append(out, *current)
		current = nil
		buf.Reset()
	}

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if mm := milestoneHeadingRE.FindStringSubmatch(line); mm != nil {
			flush()
			current = &parsedMilestone{
				number: mm[3],
				title:  strings.TrimSpace(mm[4]),
				done:   strings.TrimSpace(mm[2]) != "",
			}
			curLvl = len(mm[1])
			buf.WriteString(line)
			buf.WriteByte('\n')
			continue
		}
		if current != nil {
			if hm := generalHeadingRE.FindStringSubmatch(line); hm != nil {
				if len(hm[1]) <= curLvl {
					flush()
					continue
				}
			}
			buf.WriteString(line)
			buf.WriteByte('\n')
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("dag: scan: %w", err)
	}
	flush()
	return out, nil
}

// numberToID converts "1" → "m01", "13.2" → "m13.2".
func numberToID(num string) string {
	main := num
	suffix := ""
	if i := strings.Index(num, "."); i >= 0 {
		main = num[:i]
		suffix = num[i:]
	}
	return fmt.Sprintf("m%02s%s", main, suffix)
}

var hyphenCollapse = regexp.MustCompile(`-+`)
var nonAlnumHyphen = regexp.MustCompile(`[^a-z0-9-]`)

// slugify mirrors bash _slugify: lowercase, spaces→hyphens, strip non-alnum
// (keeping hyphens), collapse multiple hyphens, trim, truncate to 40 chars.
func slugify(text string) string {
	s := strings.ToLower(text)
	s = strings.ReplaceAll(s, " ", "-")
	s = nonAlnumHyphen.ReplaceAllString(s, "")
	s = hyphenCollapse.ReplaceAllString(s, "-")
	s = strings.Trim(s, "-")
	if len(s) > 40 {
		s = s[:40]
	}
	return s
}

var dependsOnRE = regexp.MustCompile(`(?i)[Dd]epends?\s+on\s+[Mm]ilestone\s+([0-9]+(?:\.[0-9]+)*)`)

// inferDependencies scans the milestone block for explicit "depends on
// Milestone N" references. Falls back to a sequential dep on the previous
// milestone (matching the bash _infer_dependencies fallback).
func inferDependencies(block, num string, all []parsedMilestone, idx int) []string {
	matches := dependsOnRE.FindAllStringSubmatch(block, -1)
	seen := map[string]bool{}
	var deps []string
	for _, m := range matches {
		id := numberToID(m[1])
		if !seen[id] {
			seen[id] = true
			deps = append(deps, id)
		}
	}
	if len(deps) > 0 {
		return deps
	}
	if idx > 0 {
		return []string{numberToID(all[idx-1].number)}
	}
	return nil
}

// pointerComment is the marker block that replaces inline milestone content
// after a successful migration. The two-line format must match what the bash
// _insert_milestone_pointer wrote so existing CLAUDE.md fixtures detect it.
const pointerComment = `<!-- Milestones are managed as individual files in .claude/milestones/.
     See MANIFEST.cfg for ordering and dependencies. -->`

// RewritePointer replaces inline milestone blocks in claudeMD with the
// shared pointer comment. Idempotent: returns nil and changes nothing if the
// comment already exists.
func RewritePointer(claudeMD string) error {
	if _, err := os.Stat(claudeMD); err != nil {
		return nil
	}
	data, err := os.ReadFile(claudeMD)
	if err != nil {
		return fmt.Errorf("dag: read claude.md: %w", err)
	}
	if strings.Contains(string(data), "Milestones are managed as individual files") {
		return nil
	}

	lines := strings.Split(string(data), "\n")
	var (
		out            []string
		inMilestone    bool
		milestoneLevel int
		foundAnyMilest bool
	)
	for _, line := range lines {
		if !inMilestone {
			if mm := milestoneHeadingRE.FindStringSubmatch(line); mm != nil {
				milestoneLevel = len(mm[1])
				if !foundAnyMilest {
					foundAnyMilest = true
					out = append(out, pointerComment)
					out = append(out, "")
				}
				inMilestone = true
				continue
			}
			out = append(out, line)
			continue
		}
		// inMilestone == true: skip lines until we see a heading at the same
		// or higher level that is NOT another milestone heading.
		if hm := generalHeadingRE.FindStringSubmatch(line); hm != nil {
			lvl := len(hm[1])
			if lvl <= milestoneLevel {
				if mm := milestoneHeadingRE.FindStringSubmatch(line); mm != nil {
					// Another milestone — stay inMilestone.
					milestoneLevel = len(mm[1])
					continue
				}
				inMilestone = false
				out = append(out, line)
				continue
			}
		}
		// otherwise: drop the line
	}

	if !foundAnyMilest {
		return nil
	}
	tmp, err := os.CreateTemp(filepath.Dir(claudeMD), filepath.Base(claudeMD)+".XXXXXX")
	if err != nil {
		return fmt.Errorf("dag: tmpfile: %w", err)
	}
	tmpName := tmp.Name()
	if _, err := tmp.WriteString(strings.Join(out, "\n")); err != nil {
		tmp.Close()
		_ = os.Remove(tmpName)
		return fmt.Errorf("dag: write tmp: %w", err)
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return fmt.Errorf("dag: close tmp: %w", err)
	}
	if err := os.Rename(tmpName, claudeMD); err != nil {
		_ = os.Remove(tmpName)
		return fmt.Errorf("dag: rename: %w", err)
	}
	return nil
}
