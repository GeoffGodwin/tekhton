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
