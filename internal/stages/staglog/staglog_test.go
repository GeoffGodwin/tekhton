package staglog

import (
	"bytes"
	"regexp"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// TestStaglogHeader_Format asserts the m34.1 acceptance regex for the header
// line: `[pos/count] StageName`, TitleCase stage name, single trailing newline.
func TestStaglogHeader_Format(t *testing.T) {
	var buf bytes.Buffer
	l := NewWithWriter(&buf, 2, 5)
	l.Header("Docs")
	got := strings.TrimRight(buf.String(), "\n")
	re := regexp.MustCompile(`^\[\d+/\d+\] [A-Z][a-zA-Z]+$`)
	if !re.MatchString(got) {
		t.Fatalf("header %q does not match acceptance regex", got)
	}
	if got != "[2/5] Docs" {
		t.Fatalf("header=%q want [2/5] Docs", got)
	}
}

func TestStaglogLevels_Prefixes(t *testing.T) {
	cases := []struct {
		level string
		fn    func(Logger, string)
		want  string
	}{
		{"info", func(l Logger, s string) { l.Info(s) }, "hello"},
		{"warn", func(l Logger, s string) { l.Warn(s) }, "WARN: hello"},
		{"success", func(l Logger, s string) { l.Success(s) }, "OK: hello"},
	}
	for _, tc := range cases {
		t.Run(tc.level, func(t *testing.T) {
			var buf bytes.Buffer
			l := NewWithWriter(&buf, 1, 1)
			tc.fn(l, "hello")
			got := strings.TrimRight(buf.String(), "\n")
			if got != tc.want {
				t.Fatalf("%s: got %q want %q", tc.level, got, tc.want)
			}
		})
	}
}

func TestStaglogNew_FallsBackToOnePerOne(t *testing.T) {
	// New() called with a nil request and no env keys set should yield
	// "[1/1] Docs". Use t.Setenv to clear the env keys atomically.
	t.Setenv("PIPELINE_STAGE_POS", "")
	t.Setenv("PIPELINE_STAGE_COUNT", "")
	var buf bytes.Buffer
	l := NewWithWriter(&buf, 0, 0) // 0 falls through to direct write
	_ = l                          // not exercising New() — its env path is below
}

func TestStaglogAtoiOr(t *testing.T) {
	cases := []struct {
		in, fallback, want int
		raw                string
	}{
		{want: 7, fallback: 7, raw: ""},
		{want: 7, fallback: 7, raw: "abc"},
		{want: 7, fallback: 7, raw: "-3"},
		{want: 7, fallback: 7, raw: "0"},
		{want: 42, fallback: 7, raw: "42"},
	}
	for _, c := range cases {
		got := atoiOr(c.raw, c.fallback)
		if got != c.want {
			t.Fatalf("atoiOr(%q, %d) = %d want %d", c.raw, c.fallback, got, c.want)
		}
	}
}

// TestStaglogNew_NilReq_DefaultsToOneOne verifies the production constructor
// returns a logger that renders [1/1] when both env keys are absent and req is nil.
func TestStaglogNew_NilReq_DefaultsToOneOne(t *testing.T) {
	t.Setenv(envStagePos, "")
	t.Setenv(envStageCount, "")
	l := New(nil)
	if l == nil {
		t.Fatal("New(nil) returned nil")
	}
	sl, ok := l.(*stderrLogger)
	if !ok {
		t.Fatalf("New returned type %T, want *stderrLogger", l)
	}
	if sl.pos != 1 {
		t.Fatalf("pos=%d want 1", sl.pos)
	}
	if sl.count != 1 {
		t.Fatalf("count=%d want 1", sl.count)
	}
}

// TestStaglogNew_FromEnv verifies New() reads PIPELINE_STAGE_POS and
// PIPELINE_STAGE_COUNT from the process environment when req is nil.
func TestStaglogNew_FromEnv(t *testing.T) {
	t.Setenv(envStagePos, "3")
	t.Setenv(envStageCount, "8")
	l := New(nil)
	sl, ok := l.(*stderrLogger)
	if !ok {
		t.Fatalf("New returned type %T, want *stderrLogger", l)
	}
	if sl.pos != 3 {
		t.Fatalf("pos=%d want 3", sl.pos)
	}
	if sl.count != 8 {
		t.Fatalf("count=%d want 8", sl.count)
	}
}

// TestStaglogNew_ReqEnvOverridesTakePriority verifies req.EnvOverrides overrides
// the process env when both supply PIPELINE_STAGE_POS / PIPELINE_STAGE_COUNT.
func TestStaglogNew_ReqEnvOverridesTakePriority(t *testing.T) {
	// Env says 1/1; req overrides to 5/9.
	t.Setenv(envStagePos, "1")
	t.Setenv(envStageCount, "1")
	req := &proto.StageRequestV1{
		EnvOverrides: map[string]string{
			envStagePos:   "5",
			envStageCount: "9",
		},
	}
	l := New(req)
	sl, ok := l.(*stderrLogger)
	if !ok {
		t.Fatalf("New returned type %T, want *stderrLogger", l)
	}
	if sl.pos != 5 {
		t.Fatalf("pos=%d want 5 (from req.EnvOverrides)", sl.pos)
	}
	if sl.count != 9 {
		t.Fatalf("count=%d want 9 (from req.EnvOverrides)", sl.count)
	}
}

// TestStaglogNew_ReqPartialOverride verifies that a req.EnvOverrides entry for
// only one position key leaves the other resolved from env.
func TestStaglogNew_ReqPartialOverride(t *testing.T) {
	t.Setenv(envStagePos, "2")
	t.Setenv(envStageCount, "7")
	req := &proto.StageRequestV1{
		EnvOverrides: map[string]string{
			envStagePos: "4", // only pos overridden
		},
	}
	l := New(req)
	sl := l.(*stderrLogger)
	if sl.pos != 4 {
		t.Fatalf("pos=%d want 4", sl.pos)
	}
	if sl.count != 7 {
		t.Fatalf("count=%d want 7 (from env, not overridden)", sl.count)
	}
}

// TestStaglogNewWithWriter_NilWriter verifies NewWithWriter(nil, ...) falls back
// to io.Discard and the logger methods do not panic.
func TestStaglogNewWithWriter_NilWriter(t *testing.T) {
	l := NewWithWriter(nil, 1, 1)
	if l == nil {
		t.Fatal("NewWithWriter(nil,...) returned nil")
	}
	// None of these should panic or return an error.
	l.Header("Stage")
	l.Info("msg")
	l.Warn("warn")
	l.Success("ok")
}

// TestEnvOrInt_Branches exercises the two code paths in envOrInt directly:
// the empty-env fallback and the set-env forward.
func TestEnvOrInt_Branches(t *testing.T) {
	t.Setenv("STAGLOG_TEST_INT", "")
	if got := envOrInt("STAGLOG_TEST_INT", 5); got != 5 {
		t.Fatalf("empty env: got %d want 5", got)
	}
	t.Setenv("STAGLOG_TEST_INT", "12")
	if got := envOrInt("STAGLOG_TEST_INT", 5); got != 12 {
		t.Fatalf("set env: got %d want 12", got)
	}
}

// TestStaglogNew_HeaderMatchesAcceptanceRegex asserts that a logger produced by
// the production New() constructor (not NewWithWriter) emits the correct header
// format. We capture via the stderrLogger's writer field after confirming the
// struct type.
func TestStaglogNew_HeaderMatchesAcceptanceRegex(t *testing.T) {
	t.Setenv(envStagePos, "2")
	t.Setenv(envStageCount, "5")
	l := New(nil)
	// Replace the writer with a buffer to capture output without clobbering stderr.
	var buf bytes.Buffer
	sl := l.(*stderrLogger)
	sl.w = &buf
	sl.Header("Cleanup")
	got := strings.TrimRight(buf.String(), "\n")
	re := regexp.MustCompile(`^\[\d+/\d+\] [A-Z][a-zA-Z]+$`)
	if !re.MatchString(got) {
		t.Fatalf("header %q does not match acceptance regex", got)
	}
	if got != "[2/5] Cleanup" {
		t.Fatalf("header=%q want [2/5] Cleanup", got)
	}
}
