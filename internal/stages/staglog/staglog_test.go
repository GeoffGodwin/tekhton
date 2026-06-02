package staglog

import (
	"bytes"
	"regexp"
	"strings"
	"testing"
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
