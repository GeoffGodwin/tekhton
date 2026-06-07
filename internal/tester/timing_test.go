package tester

import (
	"path/filepath"
	"testing"
)

func TestZeroTiming_AllSentinels(t *testing.T) {
	z := ZeroTiming()
	if z.ExecCount != -1 || z.ExecApproxS != -1 || z.FilesWritten != -1 || z.WritingS != -1 {
		t.Fatalf("ZeroTiming should set all fields to -1; got %+v", z)
	}
}

func TestParseTesterTiming_EmptyFile_ReturnsSentinels(t *testing.T) {
	got := ParseTesterTiming(filepath.Join("testdata", "timing", "empty.md"), ParseModeReplace)
	want := ZeroTiming()
	if got != want {
		t.Fatalf("empty fixture: want %+v, got %+v", want, got)
	}
}

func TestParseTesterTiming_FullFile_ReplaceMode(t *testing.T) {
	got := ParseTesterTiming(filepath.Join("testdata", "timing", "full.md"), ParseModeReplace)
	want := TesterTiming{ExecCount: 3, ExecApproxS: 12, FilesWritten: 5, WritingS: -1}
	if got != want {
		t.Fatalf("full fixture replace: want %+v, got %+v", want, got)
	}
}

func TestParseTesterTiming_PartialFile_LeavesUnsetFieldsSentinel(t *testing.T) {
	got := ParseTesterTiming(filepath.Join("testdata", "timing", "partial.md"), ParseModeReplace)
	want := TesterTiming{ExecCount: 4, ExecApproxS: -1, FilesWritten: -1, WritingS: -1}
	if got != want {
		t.Fatalf("partial fixture replace: want %+v, got %+v", want, got)
	}
}

func TestParseTesterTiming_MalformedFile_PicksLastNumericMatch(t *testing.T) {
	// malformed.md has two "Test executions:" lines — first malformed
	// ("about three"), second numeric ("9"). The Go port mirrors the
	// bash `... | tail -1` semantics and must pick the last match.
	got := ParseTesterTiming(filepath.Join("testdata", "timing", "malformed.md"), ParseModeReplace)
	if got.ExecCount != 9 {
		t.Fatalf("malformed fixture: want ExecCount=9 (last match), got %d", got.ExecCount)
	}
	if got.ExecApproxS != -1 {
		t.Fatalf("malformed fixture: want ExecApproxS=-1 (no numeric match), got %d", got.ExecApproxS)
	}
	if got.FilesWritten != -1 {
		t.Fatalf("malformed fixture: want FilesWritten=-1 (no numeric match), got %d", got.FilesWritten)
	}
}

func TestParseTesterTiming_MissingFile_ReturnsSentinels(t *testing.T) {
	got := ParseTesterTiming(filepath.Join("testdata", "timing", "does-not-exist.md"), ParseModeReplace)
	want := ZeroTiming()
	if got != want {
		t.Fatalf("missing fixture: want %+v, got %+v", want, got)
	}
}

func TestParseTesterTiming_EmptyPath_ReturnsSentinels(t *testing.T) {
	got := ParseTesterTiming("", ParseModeReplace)
	if got != ZeroTiming() {
		t.Fatalf("empty path: want zero sentinel, got %+v", got)
	}
}

func TestMerge_AccumulateModeAddsToRunningTotal(t *testing.T) {
	// Acceptance criterion: accumulate against {ExecCount:5, ...} from a
	// fixture with "Test executions: 3" returns ExecCount=8.
	running := TesterTiming{ExecCount: 5, ExecApproxS: 10, FilesWritten: 2, WritingS: -1}
	parsed := TesterTiming{ExecCount: 3, ExecApproxS: -1, FilesWritten: 4, WritingS: -1}
	got := running.Merge(parsed, ParseModeAccumulate)
	if got.ExecCount != 8 {
		t.Fatalf("accumulate: want ExecCount=8, got %d", got.ExecCount)
	}
	if got.ExecApproxS != 10 {
		t.Fatalf("accumulate: parsed -1 must not corrupt running 10, got %d", got.ExecApproxS)
	}
	if got.FilesWritten != 6 {
		t.Fatalf("accumulate: want FilesWritten=6, got %d", got.FilesWritten)
	}
}

func TestMerge_AccumulateModeFirstParseReplacesSentinel(t *testing.T) {
	// Watch For: "if the running total is -1 (never set), the first parse
	// replaces; subsequent parses add". Two-call accumulate guards this.
	running := ZeroTiming()
	parsed := TesterTiming{ExecCount: 3, ExecApproxS: 8, FilesWritten: 1, WritingS: -1}
	first := running.Merge(parsed, ParseModeAccumulate)
	if first.ExecCount != 3 {
		t.Fatalf("first accumulate against -1: want ExecCount=3, got %d", first.ExecCount)
	}
	if first.ExecApproxS != 8 {
		t.Fatalf("first accumulate against -1: want ExecApproxS=8, got %d", first.ExecApproxS)
	}
	second := first.Merge(parsed, ParseModeAccumulate)
	if second.ExecCount != 6 {
		t.Fatalf("second accumulate: want ExecCount=6, got %d", second.ExecCount)
	}
	if second.ExecApproxS != 16 {
		t.Fatalf("second accumulate: want ExecApproxS=16, got %d", second.ExecApproxS)
	}
}

func TestMerge_ReplaceModePreservesUnparsedFields(t *testing.T) {
	// Replace overwrites fields that were parsed (>= 0); fields parsed as
	// -1 leave the running value as-is.
	running := TesterTiming{ExecCount: 5, ExecApproxS: 10, FilesWritten: 2, WritingS: -1}
	parsed := TesterTiming{ExecCount: 3, ExecApproxS: -1, FilesWritten: -1, WritingS: -1}
	got := running.Merge(parsed, ParseModeReplace)
	if got.ExecCount != 3 {
		t.Fatalf("replace: want ExecCount=3 (parsed wins), got %d", got.ExecCount)
	}
	if got.ExecApproxS != 10 {
		t.Fatalf("replace: parsed -1 must not overwrite running 10, got %d", got.ExecApproxS)
	}
	if got.FilesWritten != 2 {
		t.Fatalf("replace: parsed -1 must not overwrite running 2, got %d", got.FilesWritten)
	}
}

func TestMergeTimingFromFile_AccumulateAcrossContinuations(t *testing.T) {
	// Continuation pattern: tester runs once -> ExecCount=3, then a
	// continuation -> ExecCount adds 4 from the same fixture (using
	// full.md as a stand-in for both passes).
	running := ZeroTiming()
	first := MergeTimingFromFile(running, filepath.Join("testdata", "timing", "full.md"), ParseModeAccumulate)
	if first.ExecCount != 3 {
		t.Fatalf("first pass: want ExecCount=3, got %d", first.ExecCount)
	}
	second := MergeTimingFromFile(first, filepath.Join("testdata", "timing", "full.md"), ParseModeAccumulate)
	if second.ExecCount != 6 {
		t.Fatalf("second pass accumulate: want ExecCount=6, got %d", second.ExecCount)
	}
	if second.ExecApproxS != 24 {
		t.Fatalf("second pass accumulate: want ExecApproxS=24, got %d", second.ExecApproxS)
	}
	if second.FilesWritten != 10 {
		t.Fatalf("second pass accumulate: want FilesWritten=10, got %d", second.FilesWritten)
	}
}

func TestComputeWritingTime_ClampsNegativeToZero(t *testing.T) {
	// Acceptance criterion: agentDuration=100, ExecApproxS=120 → 0 (NOT -20).
	timing := TesterTiming{ExecCount: 1, ExecApproxS: 120, FilesWritten: 1, WritingS: -1}
	got := ComputeWritingTime(100, timing)
	if got != 0 {
		t.Fatalf("clamp negative: want 0, got %d", got)
	}
}

func TestComputeWritingTime_NormalCase(t *testing.T) {
	timing := TesterTiming{ExecCount: 1, ExecApproxS: 30, FilesWritten: 1, WritingS: -1}
	got := ComputeWritingTime(80, timing)
	if got != 50 {
		t.Fatalf("normal case: want 50, got %d", got)
	}
}

func TestComputeWritingTime_InvalidInputsReturnSentinel(t *testing.T) {
	cases := []struct {
		name     string
		duration int
		timing   TesterTiming
	}{
		{"zero exec time", 100, TesterTiming{ExecCount: -1, ExecApproxS: 0, FilesWritten: -1, WritingS: -1}},
		{"sentinel exec time", 100, TesterTiming{ExecCount: -1, ExecApproxS: -1, FilesWritten: -1, WritingS: -1}},
		{"zero duration", 0, TesterTiming{ExecCount: -1, ExecApproxS: 30, FilesWritten: -1, WritingS: -1}},
		{"negative duration", -5, TesterTiming{ExecCount: -1, ExecApproxS: 30, FilesWritten: -1, WritingS: -1}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := ComputeWritingTime(c.duration, c.timing)
			if got != -1 {
				t.Fatalf("%s: want -1, got %d", c.name, got)
			}
		})
	}
}
