package causal

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// hasUnescapedControl returns true when s contains a byte that the bash-style
// _json_escape rules pass through unmodified but standard JSON would reject —
// i.e. a control byte (< 0x20) other than \n, \r, \t. The Go writer's escape
// helper deliberately mirrors bash here, so the JSONL line is "well-formed for
// bash readers but not strictly RFC 8259." Fuzz inputs containing such bytes
// are expected to fail json.Unmarshal — we filter them out so the fuzz target
// can still assert the JSON round-trip invariant on the safe subset.
func hasUnescapedControl(s string) bool {
	if !utf8.ValidString(s) {
		return true
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < 0x20 && c != '\n' && c != '\r' && c != '\t' {
			return true
		}
	}
	return false
}

// FuzzParseStageAndSeq exercises the resume seeder's id-extraction against
// arbitrary bytes. The function is on the hot path of every Open call, so any
// panic here would brick resume. The invariant is "never panic; on success
// the returned (stage, seq) round-trips through FormatEventID."
func FuzzParseStageAndSeq(f *testing.F) {
	seeds := []string{
		`{"id":"coder.001"}`,
		`{"id":"review.42","ts":"x"}`,
		`{"id":"pipeline.999"}`,
		`{"id":"badformat"}`,
		`{"no_id":true}`,
		``,
		`{`,
		`{"id":""}`,
		`{"id":"."}`,
		`{"id":"x."}`,
		`{"id":".1"}`,
		`{"id":"a.b.c.001"}`,
		`{"id":"coder.-1"}`,
		`{"id":"coder.0001"}`,
	}
	for _, s := range seeds {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, in []byte) {
		stage, seq := parseStageAndSeq(in)
		if stage == "" {
			return
		}
		if seq <= 0 {
			t.Errorf("non-empty stage %q paired with non-positive seq %d", stage, seq)
		}
		// Round-trip: the recovered (stage, seq) must reproduce a well-formed
		// event ID. The new ID need not match the input byte-for-byte (the
		// input may have been an unpadded seq), but it must parse back to the
		// same (stage, seq).
		id := FormatEventID(stage, seq)
		stage2, seq2 := parseStageAndSeq([]byte(`{"id":"` + id + `"}`))
		if stage2 != stage || seq2 != seq {
			t.Errorf("round-trip drift: in=(%q,%d) out=(%q,%d)", stage, seq, stage2, seq2)
		}
	})
}

// FuzzCausalEvent fuzzes the full Emit path: arbitrary detail strings must
// produce a JSONL line whose well-formed-input subset re-parses cleanly into
// the same CausalEventV1. Catches escaping regressions in proto.Quote /
// writeQuoted before they corrupt a real log.
func FuzzCausalEvent(f *testing.F) {
	seeds := []string{
		"hello",
		`hello "world"`,
		"line\nbreak",
		"tab\there",
		`back\slash`,
		"",
		strings.Repeat("a", 4096),
	}
	for _, s := range seeds {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, detail string) {
		dir := t.TempDir()
		path := filepath.Join(dir, "log.jsonl")
		l, err := Open(path, 0, "fuzz")
		if err != nil {
			t.Fatalf("Open: %v", err)
		}
		id, err := l.Emit(EmitInput{Stage: "fuzz", Type: "fuzz_evt", Detail: detail})
		if err != nil {
			t.Fatalf("Emit: %v", err)
		}
		if id == "" {
			t.Fatalf("Emit returned empty id for detail %q", detail)
		}
		lines := readLines(t, path)
		if len(lines) != 1 {
			t.Fatalf("line count = %d; want 1", len(lines))
		}
		// JSON-validity invariant only holds on inputs that the bash-style
		// escape rules can fully encode. Skip the strong assertion otherwise —
		// the no-panic invariant is what matters for fuzz coverage.
		if hasUnescapedControl(detail) {
			return
		}
		var ev proto.CausalEventV1
		if err := json.Unmarshal([]byte(lines[0]), &ev); err != nil {
			t.Fatalf("emitted line is not valid JSON: %v\n  line: %s", err, lines[0])
		}
		if ev.ID != id {
			t.Errorf("round-trip id drift: emitted=%q parsed=%q", id, ev.ID)
		}
		if ev.Detail != detail {
			t.Errorf("detail not preserved: in=%q out=%q", detail, ev.Detail)
		}
	})
}

// FuzzQuote_RoundTrip targets proto.Quote. For inputs in the safe subset
// (valid UTF-8, no unescaped control bytes besides \n\r\t) the output must be
// valid JSON that re-parses to the original. Inputs outside that subset are
// skipped — the writer mirrors bash semantics there by design.
func FuzzQuote_RoundTrip(f *testing.F) {
	seeds := []string{
		"",
		"hello",
		`with "quotes"`,
		"with\nnewline",
		"with\ttab",
		`back\slash`,
		"\r\n",
	}
	for _, s := range seeds {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, in string) {
		quoted := proto.Quote(in)
		if hasUnescapedControl(in) {
			return
		}
		var out string
		if err := json.Unmarshal([]byte(quoted), &out); err != nil {
			t.Fatalf("quoted form is not valid JSON: %v\n  in: %q\n  quoted: %s", err, in, quoted)
		}
		if out != in {
			t.Errorf("Quote round-trip drift: in=%q out=%q quoted=%s", in, out, quoted)
		}
	})
}
