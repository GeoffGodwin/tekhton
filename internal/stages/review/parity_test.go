package review

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fixtureAgentResponse models one entry under agent_responses/. Label is the
// AgentRequestV1.Label string the stub matches on; AgentResult is the canned
// return value; WriteFiles is a list of (path-relative-to-project, content)
// pairs the stub writes to disk as a side-effect of the agent call.
type fixtureAgentResponse struct {
	Label       string              `json:"label"`
	AgentResult proto.AgentResultV1 `json:"agent_result"`
	WriteFiles  []fixtureWrite      `json:"write_files,omitempty"`
}

type fixtureWrite struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

// fixtureRequest models request.json — a thin wrapper around StageRequestV1
// plus the env vars the fixture wants set before RunStage runs.
type fixtureRequest struct {
	Request proto.StageRequestV1 `json:"request"`
	Env     map[string]string    `json:"env,omitempty"`
	// SpecialistBlockers is the canned output the SpecialistRunner returns;
	// empty disables the fake specialist.
	SpecialistBlockers string `json:"specialist_blockers,omitempty"`
	// ReplanDecision is "continue" | "abort"; empty leaves the default
	// (abort) in place.
	ReplanDecision string `json:"replan_decision,omitempty"`
	// BuildGateBehaviors is a list of gate verdicts: "pass" | "fail".
	// Consumed in order by the fake build gate runner.
	BuildGateBehaviors []string `json:"build_gate_behaviors,omitempty"`
}

// fixtureExpectedResult models the subset of StageResultV1 the parity test
// asserts on. Metadata keys are encoded into Error as `k=v\n` lines.
type fixtureExpectedResult struct {
	Verdict     string            `json:"verdict"`
	ExitReason  string            `json:"exit_reason"`
	AgentCalls  int               `json:"agent_calls"`
	NextAction  string            `json:"next_action,omitempty"`
	Metadata    map[string]string `json:"metadata,omitempty"`
	HumanAction bool              `json:"human_action_required,omitempty"`
}

// loadFixtureRequest reads request.json from the fixture dir.
func loadFixtureRequest(t *testing.T, dir string) fixtureRequest {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, "request.json"))
	if err != nil {
		t.Fatalf("read request.json: %v", err)
	}
	var fr fixtureRequest
	if err := json.Unmarshal(data, &fr); err != nil {
		t.Fatalf("unmarshal request.json: %v", err)
	}
	return fr
}

// loadFixtureExpected reads expected_result.json from the fixture dir.
func loadFixtureExpected(t *testing.T, dir string) fixtureExpectedResult {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, "expected_result.json"))
	if err != nil {
		t.Fatalf("read expected_result.json: %v", err)
	}
	var fe fixtureExpectedResult
	if err := json.Unmarshal(data, &fe); err != nil {
		t.Fatalf("unmarshal expected_result.json: %v", err)
	}
	return fe
}

// loadFixtureAgentResponses reads agent_responses/*.json into a label-keyed
// map. Each file contains one fixtureAgentResponse.
func loadFixtureAgentResponses(t *testing.T, dir string) map[string][]fixtureAgentResponse {
	t.Helper()
	rdir := filepath.Join(dir, "agent_responses")
	out := map[string][]fixtureAgentResponse{}
	entries, err := os.ReadDir(rdir)
	if err != nil {
		// No agent responses (skip-only fixtures).
		return out
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(rdir, e.Name()))
		if err != nil {
			t.Fatalf("read %s: %v", e.Name(), err)
		}
		var resp fixtureAgentResponse
		if err := json.Unmarshal(data, &resp); err != nil {
			t.Fatalf("unmarshal %s: %v", e.Name(), err)
		}
		// Key the queue on the label-prefix so labels with cycle counters
		// match correctly across calls.
		key := labelKey(resp.Label)
		out[key] = append(out[key], resp)
	}
	return out
}

// labelKey collapses a runtime label like "Reviewer (cycle 2)" to
// "Reviewer (cycle" so fixtures can match any cycle for the same role.
func labelKey(label string) string {
	if i := strings.Index(label, " cycle"); i >= 0 {
		return label[:i]
	}
	if i := strings.Index(label, " ("); i >= 0 {
		return label[:i]
	}
	return label
}

// fixtureAgent replays responses keyed on labelKey.
type fixtureAgent struct {
	projectDir string
	t          *testing.T
	queues     map[string][]fixtureAgentResponse
	idx        map[string]int
	calls      []*proto.AgentRequestV1
}

func newFixtureAgent(t *testing.T, projectDir string, queues map[string][]fixtureAgentResponse) *fixtureAgent {
	return &fixtureAgent{
		projectDir: projectDir,
		t:          t,
		queues:     queues,
		idx:        map[string]int{},
	}
}

func (f *fixtureAgent) Run(_ context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	cp := *req
	f.calls = append(f.calls, &cp)
	key := labelKey(req.Label)
	q := f.queues[key]
	i := f.idx[key]
	if i >= len(q) {
		// No more canned responses for this label — return success with 0
		// turns so the stage code keeps going.
		return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 0}, nil
	}
	resp := q[i]
	f.idx[key] = i + 1
	// Side effects: write the canned files.
	for _, w := range resp.WriteFiles {
		full := filepath.Join(f.projectDir, w.Path)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			f.t.Fatalf("mkdir for %s: %v", full, err)
		}
		if err := os.WriteFile(full, []byte(w.Content), 0o644); err != nil {
			f.t.Fatalf("write %s: %v", full, err)
		}
	}
	out := resp.AgentResult
	if out.Outcome == "" {
		out.Outcome = proto.OutcomeSuccess
	}
	return &out, nil
}

// fixtureBuildGate consumes a queue of "pass"|"fail" verdicts.
type fixtureBuildGate struct {
	queue []string
	idx   int
	calls []string
}

func (f *fixtureBuildGate) Run(_ context.Context, _, stageLabel string) error {
	f.calls = append(f.calls, stageLabel)
	if f.idx >= len(f.queue) {
		return nil
	}
	verdict := f.queue[f.idx]
	f.idx++
	if verdict == "fail" {
		return fmt.Errorf("fixture build gate failed: %s", stageLabel)
	}
	return nil
}

// TestParity replays each fixture under testdata/fixtures_v4/ and asserts
// RunStage returns the expected envelope + the post-run REVIEWER_REPORT.md
// matches expected_reviewer_report.md byte-for-byte.
func TestParity(t *testing.T) {
	fixturesRoot := "testdata/fixtures_v4"
	entries, err := os.ReadDir(fixturesRoot)
	if err != nil {
		t.Fatalf("read fixtures root: %v", err)
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		t.Run(name, func(t *testing.T) {
			runParityFixture(t, filepath.Join(fixturesRoot, name))
		})
	}
}

func runParityFixture(t *testing.T, dir string) {
	t.Helper()

	fr := loadFixtureRequest(t, dir)
	expected := loadFixtureExpected(t, dir)
	queues := loadFixtureAgentResponses(t, dir)

	// Build a fresh project dir, populated with any pre-existing files the
	// fixture declares via the env "SEED_FILES" sidecar — not used yet, but
	// the contract leaves room for future seeding without rewriting parity_test.
	projectDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(projectDir, ".tekhton"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	// Layer fixture env after sane defaults — the fixture wins on conflicts.
	t.Setenv("TEKHTON_DIR", ".tekhton")
	t.Setenv("MILESTONE_MODE", "false")
	t.Setenv("REVIEW_SKIP_THRESHOLD", "0")
	t.Setenv("MAX_REVIEW_CYCLES", "3")
	t.Setenv("REVIEWER_MAX_TURNS", "20")
	t.Setenv("CODER_MAX_TURNS", "80")
	t.Setenv("JR_CODER_MAX_TURNS", "40")
	t.Setenv("REVIEWER_REPORT_FILE", ".tekhton/REVIEWER_REPORT.md")
	for k, v := range fr.Env {
		t.Setenv(k, v)
	}

	// Build the request — env-override map is rebuilt so PROJECT_DIR maps to
	// our temp dir and TEKHTON_HOME points at the repo root for prompt loads.
	req := fr.Request
	req.Proto = proto.StageRequestProtoV1
	if req.Stage == "" {
		req.Stage = proto.StageReview
	}
	if req.EnvOverrides == nil {
		req.EnvOverrides = map[string]string{}
	}
	req.EnvOverrides["PROJECT_DIR"] = projectDir
	req.EnvOverrides["TEKHTON_HOME"] = repoRoot(t)
	req.ResultFile = filepath.Join(projectDir, "result.json")

	ag := newFixtureAgent(t, projectDir, queues)
	gate := &fixtureBuildGate{queue: fr.BuildGateBehaviors}

	var replan ReplanRunner
	switch fr.ReplanDecision {
	case "continue":
		replan = &fakeReplan{Decision: replanContinue}
	case "abort":
		replan = &fakeReplan{Decision: replanUserAborted}
	}

	var spec SpecialistRunner = &fakeSpecialist{Blockers: fr.SpecialistBlockers}

	restore := installSeams(t, ag, gate, replan, spec)
	defer restore()

	res, err := RunStage(context.Background(), &req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}

	// --- Assert envelope fields ---
	if res.Verdict != expected.Verdict {
		t.Errorf("Verdict=%q want %q", res.Verdict, expected.Verdict)
	}
	if res.ExitReason != expected.ExitReason {
		t.Errorf("ExitReason=%q want %q", res.ExitReason, expected.ExitReason)
	}
	if res.AgentCalls != expected.AgentCalls {
		t.Errorf("AgentCalls=%d want %d (actual call labels: %v)",
			res.AgentCalls, expected.AgentCalls, agentLabels(ag.calls))
	}
	if expected.NextAction != "" && res.NextAction != expected.NextAction {
		t.Errorf("NextAction=%q want %q", res.NextAction, expected.NextAction)
	}
	if expected.HumanAction != res.HumanAction {
		t.Errorf("HumanAction=%v want %v", res.HumanAction, expected.HumanAction)
	}
	for k, v := range expected.Metadata {
		needle := k + "=" + v
		if !strings.Contains(res.Error, needle) {
			t.Errorf("metadata missing %q in Error blob:\n%s", needle, res.Error)
		}
	}

	// --- Byte-parity REVIEWER_REPORT.md check ---
	wantReportPath := filepath.Join(dir, "expected_reviewer_report.md")
	if _, err := os.Stat(wantReportPath); err == nil {
		want, err := os.ReadFile(wantReportPath)
		if err != nil {
			t.Fatalf("read expected_reviewer_report.md: %v", err)
		}
		got, err := os.ReadFile(filepath.Join(projectDir, ".tekhton", "REVIEWER_REPORT.md"))
		if err != nil {
			t.Fatalf("read actual REVIEWER_REPORT.md: %v", err)
		}
		if string(got) != string(want) {
			t.Errorf("REVIEWER_REPORT.md byte diff:\n--- want ---\n%s\n--- got ---\n%s", string(want), string(got))
		}
	}
}

func agentLabels(calls []*proto.AgentRequestV1) []string {
	out := make([]string, 0, len(calls))
	for _, c := range calls {
		out = append(out, c.Label)
	}
	return out
}
