package scout

import (
	"regexp"
	"strings"
)

// ShouldScoutInput captures the env / state inputs to the should-scout
// predicate. The m39.4 orchestrator resolves these from env + pipeline
// globals; tests construct them directly.
type ShouldScoutInput struct {
	// NotesFilter is the active --notes-filter value: "BUG", "FEAT",
	// "POLISH", or "" for none. Drives the per-tag branch table.
	NotesFilter string

	// ScoutOnBug / ScoutOnFeat / ScoutOnPolish mirror the env knobs
	// SCOUT_ON_BUG, SCOUT_ON_FEAT, SCOUT_ON_POLISH. Each accepts
	// "always" | "auto" | "never". Empty values use the documented
	// defaults: BUG=always, FEAT=auto, POLISH=never.
	ScoutOnBug    string
	ScoutOnFeat   string
	ScoutOnPolish string

	// DynamicTurnsEnabled mirrors DYNAMIC_TURNS_ENABLED. Default true.
	// Gates the no-tag branch and the auto-mode FEAT / POLISH branches.
	DynamicTurnsEnabled bool

	// HumanNoteCount is the number of unchecked items in HUMAN_NOTES.md
	// that the bulk-notes path is about to claim. > 0 with a NotesFilter
	// triggers the tag-branch table.
	HumanNoteCount int

	// NotesShouldClaim mirrors _m24_notes_should_claim. Bash uses this
	// to gate the human-notes-claim path; the Go port surfaces it as a
	// plain bool so callers can pre-resolve it.
	NotesShouldClaim bool

	// EstimatedTurns is the triage est_turns value extracted from
	// HUMAN_NOTES.md (the bash grep -oP 'est_turns:\K[0-9]+' result).
	// > 10 triggers the FEAT auto-mode scout branch.
	EstimatedTurns int

	// Task and NotesContent are scanned for brownfield-indicator
	// keywords (extend, add to, modify, integrate, update, change,
	// existing) by the FEAT / POLISH auto-mode branches. Empty strings
	// short-circuit the grep.
	Task         string
	NotesContent string

	// ScoutCached mirrors the dry-run cache short-circuit. When true,
	// the scout report is read from disk rather than re-spawned; the
	// predicate returns false because no live invocation is needed.
	ScoutCached bool
}

// brownfieldRE matches the seven case-insensitive keywords the bash auto
// branches grep for in TASK + NOTES_FILTER content. The leading word
// boundaries are intentional: "modify" matches, "demodify" does not.
var brownfieldRE = regexp.MustCompile(`(?i)\b(extend|add to|modify|integrate|update|change|existing)\b`)

// ShouldScout ports the 4-arm decision tree at stages/coder.sh:122-173.
//
// Truth table:
//
//	NotesFilter | Setting | Branch                         | Result
//	BUG         | always  | always                         | true
//	BUG         | auto    | always (alias for BUG)         | true
//	BUG         | never   | never                          | false
//	FEAT        | always  | always                         | true
//	FEAT        | auto    | est_turns > 10 OR brownfield   | depends
//	FEAT        | never   | never                          | false
//	POLISH      | always  | always                         | true
//	POLISH      | auto    | brownfield grep                | depends
//	POLISH      | never   | never                          | false
//	""          | n/a     | DYNAMIC_TURNS_ENABLED gate     | depends
//
// Notes-zero / claim-not-eligible falls back to the DYNAMIC_TURNS_ENABLED
// gate so a non-notes run still gets scout for complexity estimation.
// The cached-scout short-circuit always returns false — the scout has
// already run, no live invocation is needed.
func ShouldScout(in ShouldScoutInput) bool {
	if in.ScoutCached {
		return false
	}

	// Notes-driven branches (HumanNoteCount > 0 AND notes should claim).
	if in.HumanNoteCount > 0 && in.NotesShouldClaim {
		switch in.NotesFilter {
		case "BUG":
			return shouldScoutForBug(in.ScoutOnBug)
		case "FEAT":
			return shouldScoutForFeat(in.ScoutOnFeat, in.EstimatedTurns, in.Task, in.NotesContent)
		case "POLISH":
			return shouldScoutForPolish(in.ScoutOnPolish, in.Task, in.NotesContent)
		default:
			// No tag filter — fall through to the dynamic-turns gate.
			return in.DynamicTurnsEnabled
		}
	}

	// No notes / not eligible — scout for complexity estimation only
	// when DYNAMIC_TURNS_ENABLED.
	return in.DynamicTurnsEnabled
}

// shouldScoutForBug ports the BUG-tag branch. Default "always" when the
// env var is empty.
func shouldScoutForBug(setting string) bool {
	switch strings.ToLower(setting) {
	case "", "always", "auto":
		return true
	case "never":
		return false
	default:
		return true // unrecognized → default-always (bash case fallthrough)
	}
}

// shouldScoutForFeat ports the FEAT-tag branch. Default "auto" when the
// env var is empty.
func shouldScoutForFeat(setting string, estTurns int, task, notes string) bool {
	switch strings.ToLower(setting) {
	case "always":
		return true
	case "", "auto":
		if estTurns > 10 {
			return true
		}
		return brownfieldRE.MatchString(task + notes)
	case "never":
		return false
	default:
		return false
	}
}

// shouldScoutForPolish ports the POLISH-tag branch. Default "never" when
// the env var is empty.
func shouldScoutForPolish(setting string, task, notes string) bool {
	switch strings.ToLower(setting) {
	case "always":
		return true
	case "auto":
		return brownfieldRE.MatchString(task + notes)
	case "", "never":
		return false
	default:
		return false
	}
}
