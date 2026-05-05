package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
)

// useFakeAgent points the supervisor at testdata/fake_agent.sh for the
// duration of a test. The env var is the production-supported override
// path (supervisor.AgentBinaryEnv); m05's CLI tests relied on the stub
// path in supervisor.Run, which m06 replaced with a real subprocess
// launch — every CLI happy-path test needs a launchable binary now.
func useFakeAgent(t *testing.T, mode string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("fake_agent.sh requires a POSIX shell; m09 will add Windows fixtures")
	}
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skipf("bash not on PATH: %v", err)
	}
	root, err := filepath.Abs(filepath.Join("..", "..", "testdata", "fake_agent.sh"))
	if err != nil {
		t.Fatalf("abs testdata: %v", err)
	}
	t.Setenv(supervisor.AgentBinaryEnv, root)
	t.Setenv("FAKE_AGENT_MODE", mode)
}

// runSupervise is a small helper that wires stdin/stdout buffers around the
// cobra command so tests don't have to swap os.Stdin globally.
func runSupervise(t *testing.T, stdin string, args ...string) (stdout string, err error) {
	t.Helper()
	cmd := newSuperviseCmd()
	cmd.SetIn(strings.NewReader(stdin))
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetArgs(args)
	err = cmd.Execute()
	return out.String(), err
}

func validRequestJSON(t *testing.T) string {
	t.Helper()
	r := &proto.AgentRequestV1{
		Proto:      proto.AgentRequestProtoV1,
		RunID:      "rid",
		Label:      "scout",
		Model:      "claude-sonnet-4-6",
		PromptFile: "/tmp/scout.prompt",
	}
	b, err := json.Marshal(r)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return string(b)
}

// ---------------------------------------------------------------------------
// AC #1 — happy path: valid request → valid response, exit 0
// ---------------------------------------------------------------------------

func TestSuperviseCmd_HappyPath_Stdin(t *testing.T) {
	useFakeAgent(t, "happy")
	out, err := runSupervise(t, validRequestJSON(t))
	if err != nil {
		t.Fatalf("supervise: %v\noutput: %s", err, out)
	}
	var res proto.AgentResultV1
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		t.Fatalf("response not valid JSON: %v\noutput: %s", err, out)
	}
	if res.Proto != proto.AgentResultProtoV1 {
		t.Errorf("Proto: got %q, want %q", res.Proto, proto.AgentResultProtoV1)
	}
	if res.Outcome != proto.OutcomeSuccess {
		t.Errorf("Outcome: got %q", res.Outcome)
	}
	if res.ExitCode != 0 {
		t.Errorf("ExitCode: got %d", res.ExitCode)
	}
}

func TestSuperviseCmd_HappyPath_RequestFile(t *testing.T) {
	useFakeAgent(t, "happy")
	dir := t.TempDir()
	path := filepath.Join(dir, "req.json")
	if err := os.WriteFile(path, []byte(validRequestJSON(t)), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	out, err := runSupervise(t, "", "--request-file", path)
	if err != nil {
		t.Fatalf("supervise: %v\noutput: %s", err, out)
	}
	var res proto.AgentResultV1
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		t.Fatalf("response not valid JSON: %v", err)
	}
}

// ---------------------------------------------------------------------------
// AC #2 — validation rejection paths (exit code = exitUsage)
// ---------------------------------------------------------------------------

func TestSuperviseCmd_RejectsEmptyStdin(t *testing.T) {
	_, err := runSupervise(t, "")
	if err == nil {
		t.Fatal("expected error for empty stdin")
	}
	assertExitCode(t, err, exitUsage)
}

func TestSuperviseCmd_RejectsMalformedJSON(t *testing.T) {
	_, err := runSupervise(t, "{not valid json")
	if err == nil {
		t.Fatal("expected error for invalid JSON")
	}
	assertExitCode(t, err, exitUsage)
}

func TestSuperviseCmd_RejectsMissingProto(t *testing.T) {
	body := `{"label":"coder","model":"m","prompt_file":"/p"}`
	_, err := runSupervise(t, body)
	if err == nil {
		t.Fatal("expected error for missing proto")
	}
	assertExitCode(t, err, exitUsage)
}

func TestSuperviseCmd_RejectsWrongProtoVersion(t *testing.T) {
	body := `{"proto":"tekhton.agent.request.v999","label":"coder","model":"m","prompt_file":"/p"}`
	_, err := runSupervise(t, body)
	if err == nil {
		t.Fatal("expected error for wrong proto")
	}
	assertExitCode(t, err, exitUsage)
}

func TestSuperviseCmd_RejectsMissingLabel(t *testing.T) {
	body := `{"proto":"` + proto.AgentRequestProtoV1 + `","model":"m","prompt_file":"/p"}`
	_, err := runSupervise(t, body)
	if err == nil {
		t.Fatal("expected error for missing label")
	}
	assertExitCode(t, err, exitUsage)
}

func TestSuperviseCmd_RejectsMissingModel(t *testing.T) {
	body := `{"proto":"` + proto.AgentRequestProtoV1 + `","label":"c","prompt_file":"/p"}`
	_, err := runSupervise(t, body)
	if err == nil {
		t.Fatal("expected error for missing model")
	}
	assertExitCode(t, err, exitUsage)
}

func TestSuperviseCmd_RejectsMissingPromptFile(t *testing.T) {
	body := `{"proto":"` + proto.AgentRequestProtoV1 + `","label":"c","model":"m"}`
	_, err := runSupervise(t, body)
	if err == nil {
		t.Fatal("expected error for missing prompt_file")
	}
	assertExitCode(t, err, exitUsage)
}

func TestSuperviseCmd_RejectsMissingRequestFile(t *testing.T) {
	_, err := runSupervise(t, "", "--request-file", "/nonexistent/path/req.json")
	if err == nil {
		t.Fatal("expected error for missing request file")
	}
	// I/O failure (file-not-found) is exitSoftware, not exitUsage — the
	// envelope itself was never read, so it cannot be a "bad request".
	assertExitCode(t, err, exitSoftware)
}

// ---------------------------------------------------------------------------
// Round-trip parity using fixtures (AC #4 from the CLI surface)
// ---------------------------------------------------------------------------

func TestSuperviseCmd_FixtureRequestsProduceValidResponses(t *testing.T) {
	useFakeAgent(t, "happy")
	root, err := filepath.Abs(filepath.Join("..", "..", "testdata", "supervise"))
	if err != nil {
		t.Fatalf("abs testdata: %v", err)
	}
	matches, err := filepath.Glob(filepath.Join(root, "request_*.json"))
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	if len(matches) == 0 {
		t.Fatal("no request fixtures found")
	}
	for _, path := range matches {
		path := path
		t.Run(filepath.Base(path), func(t *testing.T) {
			// The full fixture sets working_dir=/home/dev/project — that
			// path won't exist in CI, so cmd.Start fails and the CLI exits
			// non-zero. The minimal fixture omits working_dir and succeeds.
			// This test guards JSON round-trip + Proto echo, not subprocess
			// outcome — the integration tests in internal/supervisor cover
			// the success/failure surface.
			out, _ := runSupervise(t, "", "--request-file", path)
			var res proto.AgentResultV1
			if err := json.Unmarshal([]byte(out), &res); err != nil {
				t.Fatalf("response parse: %v\nout: %s", err, out)
			}
			if res.Proto != proto.AgentResultProtoV1 {
				t.Errorf("Proto: got %q", res.Proto)
			}
			if res.Outcome != proto.OutcomeSuccess && res.Outcome != proto.OutcomeFatalError {
				t.Errorf("Outcome: got %q (want success or fatal_error)", res.Outcome)
			}
		})
	}
}

// assertExitCode unwraps an errExitCode and compares its code, failing the
// test if either the unwrap or the code mismatches.
func assertExitCode(t *testing.T, err error, want int) {
	t.Helper()
	var ec errExitCode
	if !errors.As(err, &ec) {
		t.Fatalf("error not errExitCode: %T %v", err, err)
	}
	if ec.ExitCode() != want {
		t.Errorf("exit code: got %d, want %d (err=%v)", ec.ExitCode(), want, err)
	}
}
