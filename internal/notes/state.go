// Package notes is the Go-side owner of HUMAN_NOTES.md and the m24 port of
// the fourteen lib/notes*.sh files. It exposes:
//
//   - the three-state state machine (Pending / Active / Done) +
//     default tag registry (BUG / FEAT / POLISH) in state.go
//   - a round-trip parser + writer for HUMAN_NOTES.md in parser.go
//   - the HUMAN_NOTES_BLOCK builder + filter in extract.go
//   - tag-specific acceptance heuristics in acceptance.go
//   - post-success cleanup + active-marker reset in cleanup.go
//   - heuristic + agent-escalated triage in triage.go
//   - V2→V3 idempotent format migrator + rollback snapshots in
//     migrate.go and rollback.go
//   - --human-mode single-note helpers in single.go
//
// The package replaces every lib/notes*.sh file in one milestone (m24).
// cmd/tekhton/note.go exposes the user-facing `tekhton note` subcommand
// tree; six internal/finalize/hooks/*.go bodies replace the bash finalize
// hooks that previously sourced lib/notes*.sh through finalize_shim.sh.
//
// Round-trip fidelity is load-bearing: HUMAN_NOTES.md is a markdown file
// users edit by hand. Mutations modify exactly the affected lines; every
// other byte is preserved. The parity gate in tests/test_notes_parity.sh
// asserts byte-identical output against captured bash baselines across
// four scenarios.
package notes

import (
	"fmt"
	"sort"
)

// State is the three-state note state machine encoded in the leading
// markdown checkbox. Mirrors the documentation in lib/notes_core.sh:
//
//	[ ] Pending — not started.
//	[~] Active  — in-scope for the current run (transient — cleared at
//	              finalize when the pipeline succeeds or fails).
//	[x] Done    — completed.
//
// The bash side encoded these as bracketed strings; Go uses a typed enum
// with explicit Checkbox()/ParseCheckbox() round-trip so the m24 parity
// gate can assert lossless conversion either direction.
type State int

const (
	// Pending corresponds to `[ ]` — a note that has not been started.
	Pending State = iota
	// Active corresponds to `[~]` — a note claimed for the current run.
	// Transient: the finalize chain clears every `[~]` marker before the
	// run ends. Either the run succeeds and the marker advances to `[x]`
	// (`resolve_notes` hook) or it fails and the marker resets to `[ ]`
	// (`failure_context_reset` hook).
	Active
	// Done corresponds to `[x]` — a completed note. Terminal state from
	// the perspective of the state machine; the cleanup_resolved hook
	// may later remove the line entirely after the retention window.
	Done
	// Deferred corresponds to `[DEFERRED]` — a note the cleanup stage
	// (m34.2) intentionally skipped. Used in NON_BLOCKING_LOG.md so the
	// item is excluded from future cleanup batches without being marked
	// resolved. HUMAN_NOTES.md does not use this state; the value lives
	// in the same enum because both files round-trip through the Notes
	// parser.
	Deferred
)

// Checkbox returns the markdown checkbox text for the state, suitable for
// substitution back into a HUMAN_NOTES.md line. Includes the brackets but
// not the surrounding `- ` list marker or trailing space.
//
// Round-trip invariant: ParseCheckbox(s.Checkbox()) == (s, nil) for every
// State value defined in this package.
func (s State) Checkbox() string {
	switch s {
	case Pending:
		return "[ ]"
	case Active:
		return "[~]"
	case Done:
		return "[x]"
	case Deferred:
		return "[DEFERRED]"
	default:
		// Defensive: an int cast outside the enum range — return the
		// Pending box so the caller's file remains valid markdown rather
		// than emitting a panic from a parser-discovered corruption.
		return "[ ]"
	}
}

// String implements fmt.Stringer for debug/log output (e.g.
// "state=Pending"). Distinct from Checkbox() — log messages want the
// readable name, file writes want the bracketed glyph.
func (s State) String() string {
	switch s {
	case Pending:
		return "Pending"
	case Active:
		return "Active"
	case Done:
		return "Done"
	case Deferred:
		return "Deferred"
	default:
		return fmt.Sprintf("State(%d)", int(s))
	}
}

// ParseCheckbox converts the markdown checkbox string back to a State.
// Accepts exactly the three canonical glyphs the writer emits. Anything
// else returns Pending and a wrapped ErrUnknownCheckbox so callers can
// distinguish "corrupted file" from "legitimate Pending entry."
func ParseCheckbox(box string) (State, error) {
	switch box {
	case "[ ]":
		return Pending, nil
	case "[~]":
		return Active, nil
	case "[x]":
		return Done, nil
	case "[DEFERRED]":
		return Deferred, nil
	default:
		return Pending, fmt.Errorf("%w: %q", ErrUnknownCheckbox, box)
	}
}

// DefaultTagPriority is the canonical priority order for the three
// built-in tags, ported from lib/notes_core.sh's `_NOTE_TAG_PRIORITY`
// array. The order is load-bearing: list output, triage report, and
// `pick_next_note` all walk tags in this order.
var DefaultTagPriority = []string{"BUG", "FEAT", "POLISH"}

// DefaultSectionForTag maps each built-in tag to the H2 section heading
// the writer expects to find it under. Ports `_NOTE_TAG_SECTION` from
// lib/notes_core.sh. New tags added via pipeline.conf inherit the
// default heading shape `## <Title-cased tag>s` (handled in
// SectionForTag).
var DefaultSectionForTag = map[string]string{
	"BUG":    "## Bugs",
	"FEAT":   "## Features",
	"POLISH": "## Polish",
}

// TagRegistry resolves tag-related lookups against the active set of
// tags. Constructed once per process with NewTagRegistry; callers query
// it from the parser, extractor, and CLI to keep the resolution policy
// in one place instead of scattering tag tables across files.
//
// The registry is read-only after construction. Custom tags from
// pipeline.conf are merged in at New time via WithExtraTags.
type TagRegistry struct {
	priority []string
	sections map[string]string
}

// NewTagRegistry returns a registry populated with the built-in BUG /
// FEAT / POLISH tags. Equivalent to `_NOTE_TAG_PRIORITY` +
// `_NOTE_TAG_SECTION` after lib/notes_core.sh sources.
func NewTagRegistry() *TagRegistry {
	r := &TagRegistry{
		priority: append([]string{}, DefaultTagPriority...),
		sections: make(map[string]string, len(DefaultSectionForTag)),
	}
	for k, v := range DefaultSectionForTag {
		r.sections[k] = v
	}
	return r
}

// WithExtraTags returns a derived registry that recognises the supplied
// extra tags in addition to the defaults. Mirrors the bash convention
// where `pipeline.conf` extends `DEFAULT_NOTE_TAGS` — order of
// appearance becomes priority order, and each gets a synthesized section
// heading of `## <Tag>` (title-cased on first letter only, matching
// bash's `tr` behavior with the legacy fallback path).
//
// Duplicates against the default tags are dropped — the default
// section/heading wins. Extra tags appear in priority order after the
// defaults so existing list output stays stable.
func (r *TagRegistry) WithExtraTags(extras []string) *TagRegistry {
	out := &TagRegistry{
		priority: append([]string{}, r.priority...),
		sections: make(map[string]string, len(r.sections)+len(extras)),
	}
	for k, v := range r.sections {
		out.sections[k] = v
	}
	seen := make(map[string]struct{}, len(out.priority))
	for _, t := range out.priority {
		seen[t] = struct{}{}
	}
	for _, t := range extras {
		if t == "" {
			continue
		}
		if _, ok := seen[t]; ok {
			continue
		}
		seen[t] = struct{}{}
		out.priority = append(out.priority, t)
		out.sections[t] = "## " + titleCaseTag(t)
	}
	return out
}

// Priority returns the tags in priority order. Read-only — the returned
// slice is a fresh copy so callers can sort/filter without affecting
// the registry.
func (r *TagRegistry) Priority() []string {
	out := make([]string, len(r.priority))
	copy(out, r.priority)
	return out
}

// IsKnown reports whether the tag is in the registry.
func (r *TagRegistry) IsKnown(tag string) bool {
	_, ok := r.sections[tag]
	return ok
}

// SectionForTag returns the H2 section heading for the tag (e.g.
// "## Bugs"). Returns the empty string when the tag is unknown — the
// caller decides whether to error out or fall back.
func (r *TagRegistry) SectionForTag(tag string) string {
	return r.sections[tag]
}

// SortKnown returns the supplied tags in registry priority order. Tags
// the registry does not know are dropped — the bash side did the same
// when building list output. The input slice is not mutated.
func (r *TagRegistry) SortKnown(tags []string) []string {
	priorityIndex := make(map[string]int, len(r.priority))
	for i, t := range r.priority {
		priorityIndex[t] = i
	}
	known := make([]string, 0, len(tags))
	for _, t := range tags {
		if _, ok := priorityIndex[t]; ok {
			known = append(known, t)
		}
	}
	sort.SliceStable(known, func(i, j int) bool {
		return priorityIndex[known[i]] < priorityIndex[known[j]]
	})
	return known
}

// titleCaseTag converts an uppercase tag (e.g. "TEST") to a singular,
// title-cased heading word ("Test"). Matches bash's
// `echo "$tag" | tr '[:upper:]' '[:lower:]'` + manual upper-first
// behavior for custom tags. Existing default tags use the explicit
// DefaultSectionForTag map so plural/non-plural variants ("Bugs",
// "Features", "Polish") are honored without per-tag pluralization
// logic.
func titleCaseTag(tag string) string {
	if tag == "" {
		return ""
	}
	first := tag[0]
	if first >= 'A' && first <= 'Z' {
		// Already upper — lowercase the rest.
		rest := tag[1:]
		buf := make([]byte, 0, len(tag))
		buf = append(buf, first)
		for i := 0; i < len(rest); i++ {
			b := rest[i]
			if b >= 'A' && b <= 'Z' {
				b += 'a' - 'A'
			}
			buf = append(buf, b)
		}
		return string(buf)
	}
	if first >= 'a' && first <= 'z' {
		first -= 'a' - 'A'
	}
	rest := tag[1:]
	buf := make([]byte, 0, len(tag))
	buf = append(buf, first)
	buf = append(buf, []byte(rest)...)
	return string(buf)
}
