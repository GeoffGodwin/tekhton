package crawler

import "testing"

func TestClassifyChangesThresholds(t *testing.T) {
	tests := []struct {
		name    string
		changes []Change
		want    Significance
	}{
		{name: "empty", changes: nil, want: Trivial},
		{
			name: "single modify root",
			changes: []Change{{Status: "M", Path: "README.md"}},
			want:    Trivial,
		},
		{
			name: "single add root only",
			changes: []Change{{Status: "A", Path: "TOPLEVEL.md"}},
			want:    Trivial,
		},
		{
			name: "single add in subdir is moderate",
			changes: []Change{{Status: "A", Path: "src/new.go"}},
			want:    Moderate,
		},
		{
			name: "one manifest edit is moderate",
			changes: []Change{{Status: "M", Path: "package.json"}},
			want:    Moderate,
		},
		{
			name: "two manifest edits is major",
			changes: []Change{
				{Status: "M", Path: "package.json"},
				{Status: "M", Path: "Cargo.toml"},
			},
			want: Major,
		},
		{
			name: "four new dirs (4 below threshold)",
			changes: []Change{
				{Status: "A", Path: "a/x.go"},
				{Status: "A", Path: "b/x.go"},
				{Status: "A", Path: "c/x.go"},
				{Status: "A", Path: "d/x.go"},
			},
			want: Moderate,
		},
		{
			name: "five new dirs hits major",
			changes: []Change{
				{Status: "A", Path: "a/x.go"},
				{Status: "A", Path: "b/x.go"},
				{Status: "A", Path: "c/x.go"},
				{Status: "A", Path: "d/x.go"},
				{Status: "A", Path: "e/x.go"},
			},
			want: Major,
		},
		{
			name: "nine deletes (9 below threshold)",
			changes: func() []Change {
				out := make([]Change, 9)
				for i := range out {
					out[i] = Change{Status: "D", Path: "f"}
				}
				return out
			}(),
			want: Trivial,
		},
		{
			name: "ten deletes hits major",
			changes: func() []Change {
				out := make([]Change, 10)
				for i := range out {
					out[i] = Change{Status: "D", Path: "f"}
				}
				return out
			}(),
			want: Major,
		},
		{
			name: "rename across dirs counts as new dir",
			changes: []Change{
				{Status: "R100", Path: "old/file.go", RenameTo: "new/file.go"},
			},
			want: Moderate,
		},
		{
			name: "rename within same dir is trivial",
			changes: []Change{
				{Status: "R100", Path: "src/a.go", RenameTo: "src/b.go"},
			},
			want: Trivial,
		},
		{
			name: "rename with no RenameTo is no-op",
			changes: []Change{{Status: "R100", Path: "src/a.go"}},
			want:    Trivial,
		},
		{
			name: "manifest add counts as both newDir + manifestChange",
			changes: []Change{{Status: "A", Path: "submodule/package.json"}},
			want:    Moderate, // 1 newDir + 1 manifest = moderate (not major)
		},
		{
			name: "manifest delete counts as both deletedFile + manifestChange",
			changes: []Change{{Status: "D", Path: "package.json"}},
			want:    Moderate, // 1 manifest change
		},
		{
			name: "empty status skipped",
			changes: []Change{
				{Status: "", Path: "x"},
				{Status: "M", Path: "x"},
			},
			want: Trivial,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ClassifyChanges(tc.changes)
			if got != tc.want {
				t.Errorf("ClassifyChanges() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestSignificanceString(t *testing.T) {
	tests := []struct {
		s    Significance
		want string
	}{
		{Trivial, "trivial"},
		{Moderate, "moderate"},
		{Major, "major"},
		{Significance(99), "trivial"}, // default fallback
	}
	for _, tc := range tests {
		if got := tc.s.String(); got != tc.want {
			t.Errorf("Significance(%d).String() = %q, want %q", tc.s, got, tc.want)
		}
	}
}
