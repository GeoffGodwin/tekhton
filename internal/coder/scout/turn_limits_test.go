package scout

import "testing"

// TestApply_TableMatrix is the milestone Goal-4 acceptance criterion:
// six rows asserting BOTH the floor invariant AND the scaling invariant.
// Each row exercises a distinct branch of Apply so a buggy implementation
// that returns only the floor (scaling broken) OR only the recommendation
// (floor broken) fails a different row.
func TestApply_TableMatrix(t *testing.T) {
	cases := []struct {
		name             string
		estimate         *Estimate
		floors           TurnLimits
		wantCoder        int
		wantReviewer     int
		wantTester       int
		invariantCovered string
	}{
		{
			name:             "trivial — scaling above floor preserved",
			estimate:         &Estimate{FilesToModify: 1, EstimatedLines: 8, Interconnected: "low", RecommendedCoder: 20, RecommendedReviewer: 8, RecommendedTester: 20},
			floors:           TurnLimits{Coder: 15, Reviewer: 5, Tester: 15},
			wantCoder:        20,
			wantReviewer:     8,
			wantTester:       20,
			invariantCovered: "scaling > floor",
		},
		{
			name:             "below floor — floor clamp applied",
			estimate:         &Estimate{FilesToModify: 1, EstimatedLines: 4, Interconnected: "low", RecommendedCoder: 10, RecommendedReviewer: 3, RecommendedTester: 12},
			floors:           TurnLimits{Coder: 15, Reviewer: 5, Tester: 15},
			wantCoder:        15,
			wantReviewer:     5,
			wantTester:       15,
			invariantCovered: "floor > scaling",
		},
		{
			name:             "milestone — large-band scaling preserved",
			estimate:         &Estimate{FilesToModify: 12, EstimatedLines: 800, Interconnected: "high", RecommendedCoder: 100, RecommendedReviewer: 18, RecommendedTester: 70},
			floors:           TurnLimits{Coder: 15, Reviewer: 5, Tester: 15},
			wantCoder:        100,
			wantReviewer:     18,
			wantTester:       70,
			invariantCovered: "large-band scaling preserved",
		},
		{
			name:             "zero recommendations — defaults preserved (parse-fail semantic)",
			estimate:         &Estimate{FilesToModify: 1, EstimatedLines: 8, Interconnected: "low"},
			floors:           TurnLimits{Coder: 15, Reviewer: 5, Tester: 15},
			wantCoder:        15,
			wantReviewer:     5,
			wantTester:       15,
			invariantCovered: "parse failure → defaults",
		},
		{
			name:             "mixed — per-field floor + scaling",
			estimate:         &Estimate{FilesToModify: 3, EstimatedLines: 50, Interconnected: "medium", RecommendedCoder: 40, RecommendedReviewer: 4, RecommendedTester: 30},
			floors:           TurnLimits{Coder: 15, Reviewer: 5, Tester: 15},
			wantCoder:        40,
			wantReviewer:     5, // 4 < floor=5 → floor wins for reviewer only
			wantTester:       30,
			invariantCovered: "per-field divergence",
		},
		{
			name:             "nil estimate — defensive default",
			estimate:         nil,
			floors:           TurnLimits{Coder: 15, Reviewer: 5, Tester: 15},
			wantCoder:        15,
			wantReviewer:     5,
			wantTester:       15,
			invariantCovered: "nil-safe",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := Apply(c.estimate, c.floors)
			if got.Coder != c.wantCoder {
				t.Fatalf("[%s] Coder = %d, want %d", c.invariantCovered, got.Coder, c.wantCoder)
			}
			if got.Reviewer != c.wantReviewer {
				t.Fatalf("[%s] Reviewer = %d, want %d", c.invariantCovered, got.Reviewer, c.wantReviewer)
			}
			if got.Tester != c.wantTester {
				t.Fatalf("[%s] Tester = %d, want %d", c.invariantCovered, got.Tester, c.wantTester)
			}
		})
	}
}

// TestDefaultFloors pins the m39.3-spec floor triple. The values are
// load-bearing for the Apply table test above — drift fails this test
// red and surfaces an out-of-band floor change before it can affect
// production runs.
func TestDefaultFloors(t *testing.T) {
	floors := DefaultFloors()
	if floors.Coder != 15 || floors.Reviewer != 5 || floors.Tester != 15 {
		t.Fatalf("DefaultFloors = %+v, want {Coder:15 Reviewer:5 Tester:15}", floors)
	}
}

// TestApply_ScalingPreservedAtMaxRow pins the scaling invariant in
// isolation: when Recommended >> floor, the output equals Recommended
// exactly (no floor masking, no clamp-down). A buggy implementation that
// returns floor unconditionally fails here even if every other test
// happens to pass.
func TestApply_ScalingPreservedAtMaxRow(t *testing.T) {
	e := &Estimate{RecommendedCoder: 200, RecommendedReviewer: 60, RecommendedTester: 120}
	got := Apply(e, TurnLimits{Coder: 15, Reviewer: 5, Tester: 15})
	if got.Coder != 200 || got.Reviewer != 60 || got.Tester != 120 {
		t.Fatalf("Apply scaling = %+v, want {200, 60, 120}", got)
	}
}

// TestApply_FloorPreservedAtMinRow pins the floor invariant in isolation:
// when every Recommended value is well below the floor, the output equals
// the floors exactly. A buggy implementation that returns Recommended
// unconditionally fails here.
func TestApply_FloorPreservedAtMinRow(t *testing.T) {
	e := &Estimate{RecommendedCoder: 1, RecommendedReviewer: 1, RecommendedTester: 1}
	got := Apply(e, TurnLimits{Coder: 80, Reviewer: 20, Tester: 50})
	if got.Coder != 80 || got.Reviewer != 20 || got.Tester != 50 {
		t.Fatalf("Apply floor = %+v, want {80, 20, 50}", got)
	}
}
