package proto

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestStageRequestEnsureProto(t *testing.T) {
	r := &StageRequestV1{}
	r.EnsureProto()
	if r.Proto != StageRequestProtoV1 {
		t.Fatalf("EnsureProto did not stamp tag: %q", r.Proto)
	}
}

func TestStageResultEnsureProto(t *testing.T) {
	r := &StageResultV1{}
	r.EnsureProto()
	if r.Proto != StageResultProtoV1 {
		t.Fatalf("EnsureProto did not stamp tag: %q", r.Proto)
	}
}

func TestStageRequestRoundTrip(t *testing.T) {
	in := &StageRequestV1{
		Proto:        StageRequestProtoV1,
		Stage:        StageCoder,
		Task:         "fix the build",
		Milestone:    "m18",
		ReviewCycle:  2,
		BuildAttempt: 1,
		EnvOverrides: map[string]string{"EFFECTIVE_CODER_MAX_TURNS": "60"},
		ResultFile:   "/tmp/result.json",
		LogFile:      "/tmp/coder.log",
	}
	b, err := in.MarshalIndented()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	out := &StageRequestV1{}
	if err := json.Unmarshal(b, out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.Stage != in.Stage || out.Task != in.Task || out.ResultFile != in.ResultFile ||
		out.ReviewCycle != in.ReviewCycle || out.BuildAttempt != in.BuildAttempt {
		t.Fatalf("round-trip mismatch:\n got: %+v\nwant: %+v", out, in)
	}
	if got := out.EnvOverrides["EFFECTIVE_CODER_MAX_TURNS"]; got != "60" {
		t.Fatalf("env override lost: %q", got)
	}
}

func TestStageResultRoundTrip(t *testing.T) {
	in := &StageResultV1{
		Proto:        StageResultProtoV1,
		Stage:        StageReview,
		Verdict:      VerdictRework,
		ExitReason:   "reviewer requested rework",
		AgentCalls:   2,
		FilesTouched: []string{"foo.go", "bar.go"},
		NextAction:   "rework",
		DurationSec:  123,
		HumanAction:  false,
	}
	b, err := in.MarshalIndented()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	out := &StageResultV1{}
	if err := json.Unmarshal(b, out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.Verdict != in.Verdict || out.NextAction != in.NextAction {
		t.Fatalf("round-trip mismatch: got %+v want %+v", out, in)
	}
	if len(out.FilesTouched) != 2 {
		t.Fatalf("files_touched lost: %v", out.FilesTouched)
	}
}

func TestStageRequestValidate(t *testing.T) {
	cases := []struct {
		name string
		req  *StageRequestV1
		want string // substring of error; "" = no error
	}{
		{
			name: "happy",
			req: &StageRequestV1{
				Proto:      StageRequestProtoV1,
				Stage:      StageIntake,
				ResultFile: "/tmp/out.json",
			},
		},
		{name: "nil", req: nil, want: "nil request"},
		{
			name: "missing proto",
			req:  &StageRequestV1{Stage: StageIntake, ResultFile: "/tmp/x"},
			want: "missing proto",
		},
		{
			name: "wrong proto",
			req:  &StageRequestV1{Proto: "wrong", Stage: StageIntake, ResultFile: "/tmp/x"},
			want: "wrong proto",
		},
		{
			name: "missing stage",
			req:  &StageRequestV1{Proto: StageRequestProtoV1, ResultFile: "/tmp/x"},
			want: "missing stage",
		},
		{
			name: "unknown stage",
			req:  &StageRequestV1{Proto: StageRequestProtoV1, Stage: "frobnicate", ResultFile: "/tmp/x"},
			want: "unknown stage",
		},
		{
			name: "negative review_cycle",
			req:  &StageRequestV1{Proto: StageRequestProtoV1, Stage: StageReview, ReviewCycle: -1, ResultFile: "/tmp/x"},
			want: "review_cycle",
		},
		{
			name: "negative build_attempt",
			req:  &StageRequestV1{Proto: StageRequestProtoV1, Stage: StageCoder, BuildAttempt: -1, ResultFile: "/tmp/x"},
			want: "build_attempt",
		},
		{
			name: "missing result_file",
			req:  &StageRequestV1{Proto: StageRequestProtoV1, Stage: StageCoder},
			want: "result_file",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.req.Validate()
			if tc.want == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tc.want)
			}
			if !errors.Is(err, ErrInvalidStageRequest) {
				t.Fatalf("error is not ErrInvalidStageRequest: %v", err)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error %q does not contain %q", err.Error(), tc.want)
			}
		})
	}
}

func TestStageResultValidate(t *testing.T) {
	cases := []struct {
		name string
		res  *StageResultV1
		want string
	}{
		{
			name: "happy",
			res: &StageResultV1{
				Proto:   StageResultProtoV1,
				Stage:   StageCoder,
				Verdict: VerdictPass,
			},
		},
		{name: "nil", res: nil, want: "nil result"},
		{
			name: "wrong proto",
			res:  &StageResultV1{Proto: "x", Stage: StageCoder, Verdict: VerdictPass},
			want: "wrong proto",
		},
		{
			name: "unknown stage",
			res:  &StageResultV1{Proto: StageResultProtoV1, Stage: "frob", Verdict: VerdictPass},
			want: "unknown stage",
		},
		{
			name: "missing verdict",
			res:  &StageResultV1{Proto: StageResultProtoV1, Stage: StageCoder},
			want: "missing verdict",
		},
		{
			name: "unknown verdict",
			res:  &StageResultV1{Proto: StageResultProtoV1, Stage: StageCoder, Verdict: "weird"},
			want: "unknown verdict",
		},
		{
			name: "negative agent_calls",
			res:  &StageResultV1{Proto: StageResultProtoV1, Stage: StageCoder, Verdict: VerdictPass, AgentCalls: -1},
			want: "agent_calls",
		},
		{
			name: "negative duration",
			res:  &StageResultV1{Proto: StageResultProtoV1, Stage: StageCoder, Verdict: VerdictPass, DurationSec: -2},
			want: "duration_sec",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.res.Validate()
			if tc.want == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tc.want)
			}
			if !errors.Is(err, ErrInvalidStageResult) {
				t.Fatalf("error is not ErrInvalidStageResult: %v", err)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error %q does not contain %q", err.Error(), tc.want)
			}
		})
	}
}

func TestIsKnownStage(t *testing.T) {
	for _, s := range []string{StageIntake, StageCoder, StageSecurity, StageReview, StageTester, StageCleanup, StageDocs} {
		if !IsKnownStage(s) {
			t.Fatalf("%q should be known", s)
		}
	}
	if IsKnownStage("nope") {
		t.Fatalf("\"nope\" should not be known")
	}
}

func TestIsKnownVerdict(t *testing.T) {
	for _, v := range []string{VerdictPass, VerdictFail, VerdictRework, VerdictBlock, VerdictSkip} {
		if !IsKnownVerdict(v) {
			t.Fatalf("%q should be known", v)
		}
	}
	if IsKnownVerdict("ok") {
		t.Fatalf("\"ok\" should not be known")
	}
}
