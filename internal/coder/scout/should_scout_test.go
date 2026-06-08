package scout

import "testing"

// TestShouldScout_BranchMatrix is the milestone Goal-5 acceptance
// criterion: a 12-row table covering every branch of the bash-port
// truth table.
func TestShouldScout_BranchMatrix(t *testing.T) {
	cases := []struct {
		name string
		in   ShouldScoutInput
		want bool
	}{
		{
			name: "BUG + always → true",
			in:   ShouldScoutInput{NotesFilter: "BUG", ScoutOnBug: "always", HumanNoteCount: 1, NotesShouldClaim: true},
			want: true,
		},
		{
			name: "BUG + auto → true (BUG auto aliases always)",
			in:   ShouldScoutInput{NotesFilter: "BUG", ScoutOnBug: "auto", HumanNoteCount: 1, NotesShouldClaim: true},
			want: true,
		},
		{
			name: "BUG + never → false",
			in:   ShouldScoutInput{NotesFilter: "BUG", ScoutOnBug: "never", HumanNoteCount: 1, NotesShouldClaim: true},
			want: false,
		},
		{
			name: "BUG + default → true (BUG default is always)",
			in:   ShouldScoutInput{NotesFilter: "BUG", HumanNoteCount: 1, NotesShouldClaim: true},
			want: true,
		},
		{
			name: "FEAT + always → true",
			in:   ShouldScoutInput{NotesFilter: "FEAT", ScoutOnFeat: "always", HumanNoteCount: 1, NotesShouldClaim: true},
			want: true,
		},
		{
			name: "FEAT + auto + est_turns > 10 → true",
			in:   ShouldScoutInput{NotesFilter: "FEAT", ScoutOnFeat: "auto", EstimatedTurns: 15, HumanNoteCount: 1, NotesShouldClaim: true},
			want: true,
		},
		{
			name: "FEAT + auto + brownfield keyword in task → true",
			in:   ShouldScoutInput{NotesFilter: "FEAT", ScoutOnFeat: "auto", Task: "extend the parser", HumanNoteCount: 1, NotesShouldClaim: true},
			want: true,
		},
		{
			name: "FEAT + auto + greenfield → false",
			in:   ShouldScoutInput{NotesFilter: "FEAT", ScoutOnFeat: "auto", Task: "write a new feature", EstimatedTurns: 5, HumanNoteCount: 1, NotesShouldClaim: true},
			want: false,
		},
		{
			name: "POLISH + never (default) → false",
			in:   ShouldScoutInput{NotesFilter: "POLISH", HumanNoteCount: 1, NotesShouldClaim: true},
			want: false,
		},
		{
			name: "POLISH + auto + brownfield → true",
			in:   ShouldScoutInput{NotesFilter: "POLISH", ScoutOnPolish: "auto", Task: "modify existing handler", HumanNoteCount: 1, NotesShouldClaim: true},
			want: true,
		},
		{
			name: "no tag + DYNAMIC_TURNS_ENABLED=true → true",
			in:   ShouldScoutInput{DynamicTurnsEnabled: true},
			want: true,
		},
		{
			name: "no tag + DYNAMIC_TURNS_ENABLED=false → false",
			in:   ShouldScoutInput{DynamicTurnsEnabled: false},
			want: false,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := ShouldScout(c.in)
			if got != c.want {
				t.Fatalf("ShouldScout(%+v) = %v, want %v", c.in, got, c.want)
			}
		})
	}
}

// TestShouldScout_CachedShortCircuit pins the cached-scout branch: when
// SCOUT_CACHED=true, ShouldScout returns false regardless of every other
// input. The scout report is read from disk; no live invocation needed.
func TestShouldScout_CachedShortCircuit(t *testing.T) {
	in := ShouldScoutInput{
		ScoutCached:         true,
		DynamicTurnsEnabled: true,
		NotesFilter:         "BUG",
		ScoutOnBug:          "always",
		HumanNoteCount:      5,
		NotesShouldClaim:    true,
	}
	if ShouldScout(in) {
		t.Fatalf("ShouldScout with ScoutCached=true = true, want false")
	}
}

// TestShouldScout_NotesNotClaimedFallsThrough pins the fallback path:
// HumanNoteCount > 0 but NotesShouldClaim=false skips the tag branch
// table and falls through to DYNAMIC_TURNS_ENABLED.
func TestShouldScout_NotesNotClaimedFallsThrough(t *testing.T) {
	in := ShouldScoutInput{
		NotesFilter:         "BUG",
		ScoutOnBug:          "never",
		HumanNoteCount:      3,
		NotesShouldClaim:    false,
		DynamicTurnsEnabled: true,
	}
	if !ShouldScout(in) {
		t.Fatalf("ShouldScout with NotesShouldClaim=false = false, want true (fallback to dynamic-turns gate)")
	}
}

// TestShouldScout_BrownfieldRegexBoundaries verifies the word-boundary
// matching in the brownfield regex: "demodify" or "preexisting" does not
// trip the auto branch.
func TestShouldScout_BrownfieldRegexBoundaries(t *testing.T) {
	in := ShouldScoutInput{
		NotesFilter:      "POLISH",
		ScoutOnPolish:    "auto",
		Task:             "demodify foo and preexisting bar",
		HumanNoteCount:   1,
		NotesShouldClaim: true,
	}
	if ShouldScout(in) {
		t.Fatalf("ShouldScout matched non-keyword tokens — word boundaries broken")
	}
}
