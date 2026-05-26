package notes

import (
	"errors"
	"testing"
)

func TestStateCheckboxRoundTrip(t *testing.T) {
	tests := []struct {
		state State
		box   string
	}{
		{Pending, "[ ]"},
		{Active, "[~]"},
		{Done, "[x]"},
	}
	for _, tc := range tests {
		if got := tc.state.Checkbox(); got != tc.box {
			t.Errorf("Checkbox(%v) = %q, want %q", tc.state, got, tc.box)
		}
		s, err := ParseCheckbox(tc.box)
		if err != nil {
			t.Errorf("ParseCheckbox(%q) returned err = %v", tc.box, err)
		}
		if s != tc.state {
			t.Errorf("ParseCheckbox(%q) = %v, want %v", tc.box, s, tc.state)
		}
	}
}

func TestParseCheckboxUnknown(t *testing.T) {
	_, err := ParseCheckbox("[?]")
	if err == nil {
		t.Fatalf("expected error for [?]")
	}
	if !errors.Is(err, ErrUnknownCheckbox) {
		t.Errorf("expected ErrUnknownCheckbox, got %v", err)
	}
}

func TestTagRegistryDefaults(t *testing.T) {
	r := NewTagRegistry()
	want := []string{"BUG", "FEAT", "POLISH"}
	got := r.Priority()
	if len(got) != len(want) {
		t.Fatalf("Priority() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("Priority()[%d] = %q, want %q", i, got[i], want[i])
		}
	}
	if r.SectionForTag("BUG") != "## Bugs" {
		t.Errorf("SectionForTag(BUG) = %q, want '## Bugs'", r.SectionForTag("BUG"))
	}
	if !r.IsKnown("FEAT") {
		t.Errorf("FEAT should be known")
	}
	if r.IsKnown("UNKNOWN") {
		t.Errorf("UNKNOWN should not be known")
	}
}

func TestTagRegistryWithExtras(t *testing.T) {
	r := NewTagRegistry().WithExtraTags([]string{"TEST", "UI", "BUG"}) // BUG dropped (dup)
	pr := r.Priority()
	want := []string{"BUG", "FEAT", "POLISH", "TEST", "UI"}
	if len(pr) != len(want) {
		t.Fatalf("Priority() = %v, want %v", pr, want)
	}
	for i, w := range want {
		if pr[i] != w {
			t.Errorf("Priority()[%d] = %q, want %q", i, pr[i], w)
		}
	}
	if r.SectionForTag("TEST") != "## Test" {
		t.Errorf("SectionForTag(TEST) = %q, want '## Test'", r.SectionForTag("TEST"))
	}
	if r.SectionForTag("UI") != "## Ui" {
		t.Errorf("SectionForTag(UI) = %q, want '## Ui'", r.SectionForTag("UI"))
	}
}

func TestTagRegistrySortKnown(t *testing.T) {
	r := NewTagRegistry()
	got := r.SortKnown([]string{"POLISH", "UNKNOWN", "BUG", "FEAT"})
	want := []string{"BUG", "FEAT", "POLISH"}
	if len(got) != len(want) {
		t.Fatalf("SortKnown = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("SortKnown[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestStateString(t *testing.T) {
	tests := []struct {
		s    State
		want string
	}{
		{Pending, "Pending"},
		{Active, "Active"},
		{Done, "Done"},
	}
	for _, tc := range tests {
		if tc.s.String() != tc.want {
			t.Errorf("State(%v).String() = %q, want %q", int(tc.s), tc.s.String(), tc.want)
		}
	}
}
