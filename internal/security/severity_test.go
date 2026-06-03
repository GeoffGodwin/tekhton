package security

import "testing"

func TestRank_KnownSeverities(t *testing.T) {
	cases := []struct {
		s    Severity
		want int
	}{
		{SeverityCritical, 4},
		{SeverityHigh, 3},
		{SeverityMedium, 2},
		{SeverityLow, 1},
	}
	for _, c := range cases {
		if got := Rank(c.s); got != c.want {
			t.Errorf("Rank(%q) = %d, want %d", c.s, got, c.want)
		}
	}
}

func TestRank_UnknownReturnsZero(t *testing.T) {
	cases := []Severity{"", "BOGUS", "high", "critical", "info"}
	for _, s := range cases {
		if got := Rank(s); got != 0 {
			t.Errorf("Rank(%q) = %d, want 0 (unknown fallback)", s, got)
		}
	}
}

// TestMeetsThreshold_AllKnownPairs covers the 4x4 matrix of known severities
// crossed with known thresholds.
func TestMeetsThreshold_AllKnownPairs(t *testing.T) {
	known := []Severity{SeverityCritical, SeverityHigh, SeverityMedium, SeverityLow}
	for _, sev := range known {
		for _, thr := range known {
			want := Rank(sev) >= Rank(thr)
			if got := MeetsThreshold(sev, thr); got != want {
				t.Errorf("MeetsThreshold(%q, %q) = %v, want %v", sev, thr, got, want)
			}
		}
	}
}

// TestMeetsThreshold_UnknownInputs documents the bash semantics that unknown
// values rank as 0, so any non-empty real threshold rejects an unknown
// severity, and an unknown threshold is met by any input (including unknown).
func TestMeetsThreshold_UnknownInputs(t *testing.T) {
	cases := []struct {
		sev, thr Severity
		want     bool
	}{
		{"BOGUS", SeverityLow, false},      // unknown sev < LOW
		{"BOGUS", SeverityCritical, false}, // unknown sev < CRITICAL
		{SeverityLow, "BOGUS", true},       // LOW >= unknown thr (rank 0)
		{SeverityCritical, "BOGUS", true},
		{"", SeverityLow, false},      // empty sev < LOW
		{SeverityCritical, "", true},  // CRITICAL >= empty thr
		{"", "", true},                // unknown >= unknown (0 >= 0)
		{"BOGUS", "BOGUS", true},      // same — both rank 0
	}
	for _, c := range cases {
		if got := MeetsThreshold(c.sev, c.thr); got != c.want {
			t.Errorf("MeetsThreshold(%q, %q) = %v, want %v", c.sev, c.thr, got, c.want)
		}
	}
}

// TestMeetsThreshold_CaseSensitive documents that bash is case-sensitive on
// the severity rank lookup; the Go port preserves this.
func TestMeetsThreshold_CaseSensitive(t *testing.T) {
	cases := []struct {
		sev, thr Severity
		want     bool
	}{
		{"high", "HIGH", false},     // lowercase rank=0 < HIGH=3
		{"HIGH", "high", true},      // HIGH=3 >= lowercase thr=0
		{"critical", "low", true},   // both rank 0
		{"Critical", "LOW", false},  // Critical rank=0 < LOW=1
	}
	for _, c := range cases {
		if got := MeetsThreshold(c.sev, c.thr); got != c.want {
			t.Errorf("MeetsThreshold(%q, %q) = %v, want %v", c.sev, c.thr, got, c.want)
		}
	}
}
