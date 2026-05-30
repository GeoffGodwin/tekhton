// parse_runs_test.go — table-driven coverage for ParseRunSummaries.

package dashboard

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestParseRunSummaries_FromMetricsJSONL(t *testing.T) {
	r := &StatusReader{}
	got, err := r.ParseRunSummaries("testdata/parsers/runs/metrics.jsonl", "", 50)
	if err != nil {
		t.Fatalf("ParseRunSummaries: %v", err)
	}
	// Fixture has 4 records, 1 is zero-turn — expect 3 after filter.
	if len(got) != 3 {
		t.Fatalf("post-filter records: want 3 (4 minus 1 zero-turn), got %d", len(got))
	}
	// Newest-first: the milestone record should be first.
	if got[0].RunType != "milestone" {
		t.Errorf("got[0].run_type: want 'milestone', got %q", got[0].RunType)
	}
	if got[0].TaskLabel != "Milestone m33.2" {
		t.Errorf("got[0].task_label: want 'Milestone m33.2', got %q", got[0].TaskLabel)
	}
	// Bug task ranks 2nd, with cycles populated for reviewer.
	if got[1].RunType != "human_bug" {
		t.Errorf("got[1].run_type: want 'human_bug', got %q", got[1].RunType)
	}
	if got[1].Stages["reviewer"].Cycles != 2 {
		t.Errorf("got[1].stages.reviewer.cycles: want 2, got %d", got[1].Stages["reviewer"].Cycles)
	}
	// Feature task ranks 3rd, distributes duration proportionally (total=120s, 14 stage-turns).
	if got[2].RunType != "human_feat" {
		t.Errorf("got[2].run_type: want 'human_feat', got %q", got[2].RunType)
	}
	if got[2].Stages["coder"].DurationS == 0 {
		t.Error("got[2].stages.coder.duration_s: want >0 (estimated proportionally)")
	}
}

func TestParseRunSummaries_FromRunSummaryFiles(t *testing.T) {
	tmp := t.TempDir()
	// Copy fixture files into tmp (don't pollute the testdata dir).
	for _, fname := range []string{"RUN_SUMMARY_20260402_120000.json", "RUN_SUMMARY_20260402_130000.json"} {
		src := filepath.Join("testdata", "parsers", "runs", fname)
		body, err := os.ReadFile(src)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(tmp, fname), body, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	r := &StatusReader{}
	// No metrics.jsonl in tmp → falls back to RUN_SUMMARY_*.json.
	got, err := r.ParseRunSummaries("", tmp, 50)
	if err != nil {
		t.Fatalf("ParseRunSummaries: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("RUN_SUMMARY fallback: want 2 records, got %d", len(got))
	}
	// Newest first by filename sort.
	if got[0].TaskLabel != "Legacy fallback test 2" {
		t.Errorf("got[0].task_label: want 'Legacy fallback test 2' (newest), got %q", got[0].TaskLabel)
	}
	// M132 enrichment present.
	if got[0].BuildFixOutcome != "passed" {
		t.Errorf("got[0].build_fix_outcome: want 'passed', got %q", got[0].BuildFixOutcome)
	}
	if got[0].RecoveryRoute != "retry" {
		t.Errorf("got[0].recovery_route: want 'retry', got %q", got[0].RecoveryRoute)
	}
	// total_agent_calls fallback for the older record.
	if got[1].TotalTurns != 25 {
		t.Errorf("got[1].total_turns: want 25 (from total_agent_calls), got %d", got[1].TotalTurns)
	}
	// Default enrichment defaults for records lacking the fields.
	if got[1].BuildFixOutcome != "not_run" {
		t.Errorf("got[1].build_fix_outcome: want 'not_run' default, got %q", got[1].BuildFixOutcome)
	}
	if got[1].RecoveryRoute != "save_exit" {
		t.Errorf("got[1].recovery_route: want 'save_exit' default, got %q", got[1].RecoveryRoute)
	}
}

func TestParseRunSummaries_MissingInputs(t *testing.T) {
	r := &StatusReader{}
	got, err := r.ParseRunSummaries("", "", 50)
	if err != nil {
		t.Fatalf("want nil err on missing inputs, got %v", err)
	}
	if len(got) != 0 {
		t.Errorf("missing-inputs: want empty slice, got %d entries", len(got))
	}
}

func TestParseRunSummaries_ZeroDepthFallsBackTo50(t *testing.T) {
	// depth=0 must not produce an empty slice if records exist; the
	// emitter passes a clamp-to-50 default but the StatusReader itself
	// should also clamp so the Cobra CLI's --depth=0 doesn't surprise users.
	r := &StatusReader{}
	got, _ := r.ParseRunSummaries("testdata/parsers/runs/metrics.jsonl", "", 0)
	if len(got) != 3 {
		t.Errorf("depth=0 must fall back to default 50: want 3 records, got %d", len(got))
	}
}

func TestRecordToSummary_RunTypeDerivation(t *testing.T) {
	cases := []struct {
		name     string
		rec      metricsRecord
		wantType string
	}{
		{"milestone", metricsRecord{MilestoneMode: true, TaskType: "feature", TotalTurns: 10}, "milestone"},
		{"bug", metricsRecord{TaskType: "bug", TotalTurns: 10}, "human_bug"},
		{"feature", metricsRecord{TaskType: "feature", TotalTurns: 10}, "human_feat"},
		{"polish", metricsRecord{TaskType: "polish", TotalTurns: 10}, "human_polish"},
		{"drift", metricsRecord{TaskType: "drift", TotalTurns: 10}, "drift"},
		{"adhoc default", metricsRecord{TotalTurns: 10}, "adhoc"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := recordToSummary(&c.rec)
			if got.RunType != c.wantType {
				t.Errorf("run_type: want %q, got %q", c.wantType, got.RunType)
			}
		})
	}
}

func TestEstimateMissingDurations(t *testing.T) {
	stages := map[string]proto.DashboardRunSummaryStage{
		"coder":    {Turns: 6, DurationS: 0},
		"reviewer": {Turns: 4, DurationS: 0},
	}
	estimateMissingDurations(100, stages)
	if stages["coder"].DurationS != 60 || stages["reviewer"].DurationS != 40 {
		t.Errorf("proportional split: want coder=60 reviewer=40, got %+v", stages)
	}
}

func TestEstimateMissingDurations_NoOpWhenAnyDurationPresent(t *testing.T) {
	stages := map[string]proto.DashboardRunSummaryStage{
		"coder":    {Turns: 6, DurationS: 90}, // already populated
		"reviewer": {Turns: 4, DurationS: 0},
	}
	estimateMissingDurations(200, stages)
	if stages["reviewer"].DurationS != 0 {
		t.Errorf("estimation should be a no-op when ANY stage has a duration; got %+v", stages)
	}
}
