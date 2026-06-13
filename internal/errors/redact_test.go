package errors_test

import (
	"strings"
	"testing"

	terr "github.com/geoffgodwin/tekhton/internal/errors"
)

func TestRedact_PreservesRequestID(t *testing.T) {
	t.Parallel()
	in := "request id: req_abcd1234efgh"
	out := terr.Redact(in)
	if !strings.Contains(out, "req_abcd1234efgh") {
		t.Errorf("request id stripped: %q", out)
	}
}

func TestRedact_StripsAPIKey(t *testing.T) {
	t.Parallel()
	in := "X-Api-Key: sk-ant-abcdef"
	out := terr.Redact(in)
	if strings.Contains(out, "sk-ant-abcdef") {
		t.Errorf("api key not redacted: %q", out)
	}
	if !strings.Contains(out, "[REDACTED]") {
		t.Errorf("redaction marker missing: %q", out)
	}
}

func TestRedact_StripsAuthorization(t *testing.T) {
	t.Parallel()
	in := "Authorization: Bearer abc.def.ghi"
	out := terr.Redact(in)
	if strings.Contains(out, "abc.def.ghi") {
		t.Errorf("authorization not redacted: %q", out)
	}
}

func TestRedact_StripsBearerToken(t *testing.T) {
	t.Parallel()
	in := "header value bearer abc-def_xyz.123"
	out := terr.Redact(in)
	if strings.Contains(out, "abc-def_xyz.123") {
		t.Errorf("bearer token not redacted: %q", out)
	}
}

func TestRedact_StripsAnthropicEnv(t *testing.T) {
	t.Parallel()
	in := "ANTHROPIC_API_KEY=sk-ant-test something"
	out := terr.Redact(in)
	if strings.Contains(out, "sk-ant-test") {
		t.Errorf("env api key not redacted: %q", out)
	}
}

func TestRedact_PreservesPlainText(t *testing.T) {
	t.Parallel()
	in := "this is just normal output with nothing sensitive."
	out := terr.Redact(in)
	if out != in {
		t.Errorf("plain text mutated: %q -> %q", in, out)
	}
}

func TestRedact_EnvAssignment(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"codex", "CODEX_API_KEY=sk-test-1234567890abcdef", "CODEX_API_KEY=[REDACTED]"},
		{"openai", "OPENAI_API_KEY=sk-proj-abc123", "OPENAI_API_KEY=[REDACTED]"},
		{"anthropic", "ANTHROPIC_API_KEY=sk-ant-secret trailing", "ANTHROPIC_API_KEY=[REDACTED] trailing"},
		{"mid-string", "prefix CODEX_API_KEY=tok-abc suffix", "prefix CODEX_API_KEY=[REDACTED] suffix"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			out := terr.Redact(tc.in)
			if out != tc.want {
				t.Errorf("got %q, want %q", out, tc.want)
			}
		})
	}
}

func TestRedact_APIKeyAssignment(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name  string
		in    string
		value string // must not appear in output
	}{
		{"underscore equals", `api_key=mysecretvalue`, "mysecretvalue"},
		{"hyphen equals", `api-key=topsecret`, "topsecret"},
		{"underscore with spaces", `api_key = padded_secret`, "padded_secret"},
		{"embedded in line", `config: api_key=tok-abc end`, "tok-abc"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			out := terr.Redact(tc.in)
			if strings.Contains(out, tc.value) {
				t.Errorf("sensitive value %q still present in %q", tc.value, out)
			}
		})
	}
}

func TestRedact_Negative(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		in   string
	}{
		{"plain word apikey no equals", "apikey is a thing"},
		{"lowercase env no underscore", "my_api=value"},
		{"request id preserved", "req_abcd1234efgh5678"},
		{"no sensitive content", "build failed: exit code 1"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			out := terr.Redact(tc.in)
			if strings.Contains(out, "[REDACTED]") {
				t.Errorf("falsely redacted %q -> %q", tc.in, out)
			}
		})
	}
}
