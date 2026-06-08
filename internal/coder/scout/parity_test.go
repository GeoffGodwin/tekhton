package scout

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// fixtureExpected captures the JSON shape under
// internal/coder/testdata/scout/<scenario>/expected.json.
type fixtureExpected struct {
	Comment  string `json:"comment"`
	Estimate struct {
		FilesToModify       int    `json:"files_to_modify"`
		EstimatedLines      int    `json:"estimated_lines"`
		Interconnected      string `json:"interconnected"`
		RecommendedCoder    int    `json:"recommended_coder"`
		RecommendedReviewer int    `json:"recommended_reviewer"`
		RecommendedTester   int    `json:"recommended_tester"`
	} `json:"estimate"`
	AppliedWithDefaultFloors struct {
		Coder    int `json:"coder"`
		Reviewer int `json:"reviewer"`
		Tester   int `json:"tester"`
	} `json:"applied_with_default_floors"`
	AboveSplitThreshold bool `json:"above_split_threshold"`
}

func loadScoutFixture(t *testing.T, scenario string) (reportPath string, exp fixtureExpected) {
	t.Helper()
	base := filepath.Join("..", "testdata", "scout", scenario)
	reportPath = filepath.Join(base, "SCOUT_REPORT.md")
	if _, err := os.Stat(reportPath); err != nil {
		t.Fatalf("fixture %s: %v", scenario, err)
	}
	expBytes, err := os.ReadFile(filepath.Join(base, "expected.json"))
	if err != nil {
		t.Fatalf("fixture %s: read expected.json: %v", scenario, err)
	}
	if err := json.Unmarshal(expBytes, &exp); err != nil {
		t.Fatalf("fixture %s: decode expected.json: %v", scenario, err)
	}
	return reportPath, exp
}

// TestParity_TrivialEstimateAndApply drives the trivial fixture through
// ParseEstimate + Apply. Asserts both that the parser extracts the
// declared fields byte-identically and that Apply preserves the scaling
// invariant against DefaultFloors.
func TestParity_TrivialEstimateAndApply(t *testing.T) {
	reportPath, exp := loadScoutFixture(t, "trivial")

	est, err := ParseEstimate(reportPath)
	if err != nil {
		t.Fatalf("ParseEstimate: %v", err)
	}
	if est == nil {
		t.Fatalf("ParseEstimate returned nil")
	}

	if est.FilesToModify != exp.Estimate.FilesToModify {
		t.Fatalf("FilesToModify = %d, want %d", est.FilesToModify, exp.Estimate.FilesToModify)
	}
	if est.EstimatedLines != exp.Estimate.EstimatedLines {
		t.Fatalf("EstimatedLines = %d, want %d", est.EstimatedLines, exp.Estimate.EstimatedLines)
	}
	if est.Interconnected != exp.Estimate.Interconnected {
		t.Fatalf("Interconnected = %q, want %q", est.Interconnected, exp.Estimate.Interconnected)
	}
	if est.RecommendedCoder != exp.Estimate.RecommendedCoder {
		t.Fatalf("RecommendedCoder = %d, want %d", est.RecommendedCoder, exp.Estimate.RecommendedCoder)
	}
	if est.RecommendedReviewer != exp.Estimate.RecommendedReviewer {
		t.Fatalf("RecommendedReviewer = %d, want %d", est.RecommendedReviewer, exp.Estimate.RecommendedReviewer)
	}
	if est.RecommendedTester != exp.Estimate.RecommendedTester {
		t.Fatalf("RecommendedTester = %d, want %d", est.RecommendedTester, exp.Estimate.RecommendedTester)
	}

	applied := Apply(est, DefaultFloors())
	if applied.Coder != exp.AppliedWithDefaultFloors.Coder {
		t.Fatalf("Apply Coder = %d, want %d", applied.Coder, exp.AppliedWithDefaultFloors.Coder)
	}
	if applied.Reviewer != exp.AppliedWithDefaultFloors.Reviewer {
		t.Fatalf("Apply Reviewer = %d, want %d", applied.Reviewer, exp.AppliedWithDefaultFloors.Reviewer)
	}
	if applied.Tester != exp.AppliedWithDefaultFloors.Tester {
		t.Fatalf("Apply Tester = %d, want %d", applied.Tester, exp.AppliedWithDefaultFloors.Tester)
	}
}

// TestParity_LargeWithSplit drives the large-with-split fixture. m39.3
// only asserts the parser surfaces an estimate above the typical split
// threshold (so the m39.4 orchestrator's check_milestone_size can
// branch on it); the split orchestration itself lands in m39.4.
func TestParity_LargeWithSplit(t *testing.T) {
	reportPath, exp := loadScoutFixture(t, "large-with-split")

	est, err := ParseEstimate(reportPath)
	if err != nil {
		t.Fatalf("ParseEstimate: %v", err)
	}
	if est == nil {
		t.Fatalf("ParseEstimate returned nil")
	}
	if est.RecommendedCoder != exp.Estimate.RecommendedCoder {
		t.Fatalf("RecommendedCoder = %d, want %d", est.RecommendedCoder, exp.Estimate.RecommendedCoder)
	}

	applied := Apply(est, DefaultFloors())
	if applied.Coder != exp.AppliedWithDefaultFloors.Coder {
		t.Fatalf("Apply Coder = %d, want %d", applied.Coder, exp.AppliedWithDefaultFloors.Coder)
	}
	if applied.Reviewer != exp.AppliedWithDefaultFloors.Reviewer {
		t.Fatalf("Apply Reviewer = %d, want %d", applied.Reviewer, exp.AppliedWithDefaultFloors.Reviewer)
	}
	if applied.Tester != exp.AppliedWithDefaultFloors.Tester {
		t.Fatalf("Apply Tester = %d, want %d", applied.Tester, exp.AppliedWithDefaultFloors.Tester)
	}

	// The "above split threshold" signal is m39.4's gate; m39.3 just
	// surfaces the raw recommendation. The fixture's threshold marker
	// is informational here.
	if exp.AboveSplitThreshold && applied.Coder < 80 {
		t.Fatalf("expected above-threshold scaling, got Coder=%d", applied.Coder)
	}
}
