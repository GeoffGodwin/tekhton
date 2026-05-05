package proto

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// testdataDir resolves the repo-root-relative testdata/supervise directory.
// Tests run from internal/proto so we walk up two directories.
func testdataDir(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", "testdata", "supervise"))
	if err != nil {
		t.Fatalf("abs testdata: %v", err)
	}
	if _, err := os.Stat(root); err != nil {
		t.Fatalf("testdata missing: %v", err)
	}
	return root
}

// ---------------------------------------------------------------------------
// Round-trip parity — AC #4
// ---------------------------------------------------------------------------

// roundTripBytesIdentical asserts that marshaling, unmarshaling, and
// re-marshaling produces byte-identical output. The fixture itself need not
// equal the marshaled form; only the second-pass marshal must match the first.
func roundTripBytesIdentical[T any](t *testing.T, raw []byte, mk func() *T, marshal func(*T) ([]byte, error)) {
	t.Helper()
	first := mk()
	if err := json.Unmarshal(raw, first); err != nil {
		t.Fatalf("first unmarshal: %v", err)
	}
	firstBytes, err := marshal(first)
	if err != nil {
		t.Fatalf("first marshal: %v", err)
	}
	second := mk()
	if err := json.Unmarshal(firstBytes, second); err != nil {
		t.Fatalf("second unmarshal: %v", err)
	}
	secondBytes, err := marshal(second)
	if err != nil {
		t.Fatalf("second marshal: %v", err)
	}
	if !bytes.Equal(firstBytes, secondBytes) {
		t.Errorf("round-trip not byte-identical:\n--- first ---\n%s\n--- second ---\n%s",
			string(firstBytes), string(secondBytes))
	}
}

func TestAgentRequestV1_RoundTripFixtures(t *testing.T) {
	dir := testdataDir(t)
	matches, err := filepath.Glob(filepath.Join(dir, "request_*.json"))
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	if len(matches) == 0 {
		t.Fatal("no request fixtures found")
	}
	for _, path := range matches {
		path := path
		t.Run(filepath.Base(path), func(t *testing.T) {
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read fixture: %v", err)
			}
			roundTripBytesIdentical(t, raw,
				func() *AgentRequestV1 { return &AgentRequestV1{} },
				func(r *AgentRequestV1) ([]byte, error) { return r.MarshalIndented() },
			)
		})
	}
}

func TestAgentResultV1_RoundTripFixtures(t *testing.T) {
	dir := testdataDir(t)
	matches, err := filepath.Glob(filepath.Join(dir, "response_*.json"))
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	if len(matches) == 0 {
		t.Fatal("no response fixtures found")
	}
	for _, path := range matches {
		path := path
		t.Run(filepath.Base(path), func(t *testing.T) {
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read fixture: %v", err)
			}
			roundTripBytesIdentical(t, raw,
				func() *AgentResultV1 { return &AgentResultV1{} },
				func(r *AgentResultV1) ([]byte, error) { return r.MarshalIndented() },
			)
		})
	}
}

// TestAgentRequestV1_FixtureStructuralFields spot-checks that the fixture
// loaded back into a struct preserves the values we expect — guards against
// a future tag rename quietly dropping fields.
func TestAgentRequestV1_FixtureStructuralFields(t *testing.T) {
	dir := testdataDir(t)
	raw, err := os.ReadFile(filepath.Join(dir, "request_full.json"))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var r AgentRequestV1
	if err := json.Unmarshal(raw, &r); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if r.Proto != AgentRequestProtoV1 {
		t.Errorf("Proto: got %q, want %q", r.Proto, AgentRequestProtoV1)
	}
	if r.Label != "coder" || r.Model != "claude-opus-4-7" {
		t.Errorf("Label/Model: got %q/%q", r.Label, r.Model)
	}
	if r.MaxTurns != 60 || r.TimeoutSecs != 1800 || r.ActivityTimeoutSecs != 600 {
		t.Errorf("ints: %+v", r)
	}
	if got := r.EnvOverrides["TEKHTON_RUN_ID"]; got != "run_20260505_120000" {
		t.Errorf("EnvOverrides[TEKHTON_RUN_ID]: got %q", got)
	}
}

func TestAgentResultV1_FixtureStructuralFields(t *testing.T) {
	dir := testdataDir(t)
	raw, err := os.ReadFile(filepath.Join(dir, "response_transient_error.json"))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var r AgentResultV1
	if err := json.Unmarshal(raw, &r); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if r.Proto != AgentResultProtoV1 {
		t.Errorf("Proto: got %q, want %q", r.Proto, AgentResultProtoV1)
	}
	if r.Outcome != OutcomeTransientError {
		t.Errorf("Outcome: got %q, want %q", r.Outcome, OutcomeTransientError)
	}
	if r.ErrorCategory != "UPSTREAM" || !r.ErrorTransient {
		t.Errorf("error fields: %+v", r)
	}
	if len(r.StdoutTail) != 3 {
		t.Errorf("StdoutTail len: got %d, want 3", len(r.StdoutTail))
	}
}

func TestAgentResultV1_MarshalIndented_StablePrefix(t *testing.T) {
	r := &AgentResultV1{Proto: AgentResultProtoV1, ExitCode: 0, Outcome: OutcomeSuccess}
	data, err := r.MarshalIndented()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !bytes.HasPrefix(data, []byte("{\n  \"proto\":")) {
		t.Errorf("MarshalIndented prefix unexpected: %s", string(data))
	}
}
