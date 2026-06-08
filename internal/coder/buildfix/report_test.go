package buildfix

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestAppendReport_ByteIdenticalWithBashBaseline replays the same three
// attempts that produced `testdata/buildfix/report-baseline.md` against
// AppendReport and asserts byte-identical output after timestamp
// normalization.
func TestAppendReport_ByteIdenticalWithBashBaseline(t *testing.T) {
	withFrozenClock(t, time.Date(2026, 6, 1, 10, 23, 45, 0, time.UTC))

	path := filepath.Join(t.TempDir(), "BUILD_FIX_REPORT.md")
	attempts := []AttemptReport{
		{
			Attempt:         1,
			Budget:          27,
			TerminalClass:   ClassMaxTurns,
			GateResult:      "fail",
			ProgressSignal:  SignalImproved,
			ErrorCountDelta: "12→5",
			Classification:  DecisionCodeDominant,
		},
		{
			Attempt:         2,
			Budget:          40,
			TerminalClass:   ClassSuccess,
			GateResult:      "pass",
			ProgressSignal:  SignalImproved,
			ErrorCountDelta: "5→0",
			Classification:  DecisionCodeDominant,
		},
		{
			Attempt:         3,
			Budget:          54,
			TerminalClass:   ClassMaxTurns,
			GateResult:      "fail",
			ProgressSignal:  SignalUnchanged,
			ErrorCountDelta: "0→0",
			Classification:  DecisionMixedUncertain,
		},
	}
	for i, r := range attempts {
		if err := AppendReport(path, r); err != nil {
			t.Fatalf("AppendReport attempt %d: %v", i+1, err)
		}
	}

	gotBytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read produced report: %v", err)
	}
	wantBytes, err := os.ReadFile("../testdata/buildfix/report-baseline.md")
	if err != nil {
		t.Fatalf("read baseline: %v", err)
	}
	got := normalizeTimestamp(string(gotBytes))
	want := string(wantBytes)
	if got != want {
		t.Fatalf("AppendReport output diverged from baseline.\n--- got ---\n%s\n--- want ---\n%s",
			got, want)
	}
}

// TestAppendReport_AppendsRatherThanOverwrites pins the
// open-append-create semantics. Three calls must produce three
// `## Attempt N` sections, not one with the last attempt overwriting the
// others.
func TestAppendReport_AppendsRatherThanOverwrites(t *testing.T) {
	withFrozenClock(t, time.Date(2026, 6, 1, 10, 0, 0, 0, time.UTC))
	path := filepath.Join(t.TempDir(), "BUILD_FIX_REPORT.md")
	for i := 1; i <= 3; i++ {
		if err := AppendReport(path, AttemptReport{
			Attempt: i, Budget: 10, TerminalClass: ClassSuccess,
			GateResult: "pass", ProgressSignal: SignalImproved,
			ErrorCountDelta: "0→0", Classification: DecisionCodeDominant,
		}); err != nil {
			t.Fatalf("AppendReport %d: %v", i, err)
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	got := strings.Count(string(data), "## Attempt ")
	if got != 3 {
		t.Fatalf("got %d `## Attempt` sections, want 3 — append vs overwrite regression", got)
	}
}

// TestAppendReport_HeaderOnlyOnFirstCall asserts the bash
// `if [[ ! -f "$file" ]]` guard semantic: the header heredoc is written
// only when the file does not pre-exist.
func TestAppendReport_HeaderOnlyOnFirstCall(t *testing.T) {
	withFrozenClock(t, time.Date(2026, 6, 1, 10, 0, 0, 0, time.UTC))
	path := filepath.Join(t.TempDir(), "BUILD_FIX_REPORT.md")
	for i := 1; i <= 2; i++ {
		if err := AppendReport(path, AttemptReport{
			Attempt: i, Budget: 10, TerminalClass: ClassSuccess,
			GateResult: "pass", ProgressSignal: SignalImproved,
			ErrorCountDelta: "0→0", Classification: DecisionCodeDominant,
		}); err != nil {
			t.Fatalf("AppendReport %d: %v", i, err)
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if got := strings.Count(string(data), "# Build-Fix Report"); got != 1 {
		t.Fatalf("got %d `# Build-Fix Report` headers, want exactly 1", got)
	}
}

// TestAppendReport_CreatesMissingDir mirrors the bash `mkdir -p` step.
func TestAppendReport_CreatesMissingDir(t *testing.T) {
	withFrozenClock(t, time.Date(2026, 6, 1, 10, 0, 0, 0, time.UTC))
	dir := filepath.Join(t.TempDir(), "nested", "deep")
	path := filepath.Join(dir, "BUILD_FIX_REPORT.md")
	if err := AppendReport(path, AttemptReport{
		Attempt: 1, Budget: 10, TerminalClass: ClassSuccess,
		GateResult: "pass", ProgressSignal: SignalImproved,
		ErrorCountDelta: "0→0", Classification: DecisionCodeDominant,
	}); err != nil {
		t.Fatalf("AppendReport: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("expected file to exist at %s: %v", path, err)
	}
}

// TestEmitRoutingDiagnosis_ByteIdenticalWithBashBaseline drives the
// helper from the recorded stats fixture and diffs against the captured
// bash baseline (timestamp normalized).
func TestEmitRoutingDiagnosis_ByteIdenticalWithBashBaseline(t *testing.T) {
	withFrozenClock(t, time.Date(2026, 6, 1, 10, 23, 45, 0, time.UTC))

	stats, err := os.ReadFile("../testdata/buildfix/routing-stats-fixture.txt")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	out := filepath.Join(t.TempDir(), "BUILD_ROUTING_DIAGNOSIS.md")
	if err := EmitRoutingDiagnosis(out, string(stats)); err != nil {
		t.Fatalf("EmitRoutingDiagnosis: %v", err)
	}
	gotBytes, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("read out: %v", err)
	}
	wantBytes, err := os.ReadFile("../testdata/buildfix/routing-diagnosis-baseline.md")
	if err != nil {
		t.Fatalf("read baseline: %v", err)
	}
	got := normalizeTimestamp(string(gotBytes))
	want := string(wantBytes)
	if got != want {
		t.Fatalf("EmitRoutingDiagnosis diverged from baseline.\n--- got ---\n%s\n--- want ---\n%s",
			got, want)
	}
}

// TestEmitRoutingDiagnosis_EmptyStats renders the
// "(no recognized signatures)" placeholder under "## Top Diagnoses" when
// statsText is empty.
func TestEmitRoutingDiagnosis_EmptyStats(t *testing.T) {
	withFrozenClock(t, time.Date(2026, 6, 1, 10, 0, 0, 0, time.UTC))
	out := filepath.Join(t.TempDir(), "BUILD_ROUTING_DIAGNOSIS.md")
	if err := EmitRoutingDiagnosis(out, ""); err != nil {
		t.Fatalf("EmitRoutingDiagnosis: %v", err)
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	body := string(data)
	if !strings.Contains(body, "- (no recognized signatures)") {
		t.Fatalf("empty stats should render placeholder; got:\n%s", body)
	}
	if !strings.Contains(body, "- considered: 0") || !strings.Contains(body, "- matched: 0") || !strings.Contains(body, "- unmatched: 0") {
		t.Fatalf("empty stats should yield zero line counts; got:\n%s", body)
	}
}

// TestEmitRoutingDiagnosis_TopThreeOnly asserts the top-three cap even
// when the stats stream has more than three records.
func TestEmitRoutingDiagnosis_TopThreeOnly(t *testing.T) {
	withFrozenClock(t, time.Date(2026, 6, 1, 10, 0, 0, 0, time.UTC))
	stats := "code|safe|cmd1|d1|10|30|100|70\n" +
		"code|safe|cmd2|d2|8|30|100|70\n" +
		"code|safe|cmd3|d3|6|30|100|70\n" +
		"code|safe|cmd4|d4|4|30|100|70\n" +
		"code|safe|cmd5|d5|2|30|100|70\n"
	out := filepath.Join(t.TempDir(), "BUILD_ROUTING_DIAGNOSIS.md")
	if err := EmitRoutingDiagnosis(out, stats); err != nil {
		t.Fatalf("EmitRoutingDiagnosis: %v", err)
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	body := string(data)
	if !strings.Contains(body, "d1") || !strings.Contains(body, "d2") || !strings.Contains(body, "d3") {
		t.Fatalf("top three should appear; got:\n%s", body)
	}
	if strings.Contains(body, "d4") || strings.Contains(body, "d5") {
		t.Fatalf("only top three should appear (d4/d5 must be excluded); got:\n%s", body)
	}
}
