package proto

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestPipelineRequestValidate(t *testing.T) {
	cases := []struct {
		name string
		req  *PipelineAttemptRequestV1
		want string
	}{
		{
			name: "happy",
			req: &PipelineAttemptRequestV1{
				Proto:       PipelineAttemptRequestProtoV1,
				Order:       []string{StageCoder, StageReview, StageTester},
				ReviewCycle: 1,
				ProjectDir:  "/tmp/proj",
			},
		},
		{name: "nil", req: nil, want: "nil request"},
		{
			name: "wrong proto",
			req:  &PipelineAttemptRequestV1{Proto: "x", Order: []string{StageCoder}, ProjectDir: "/x"},
			want: "wrong proto",
		},
		{
			name: "empty order",
			req:  &PipelineAttemptRequestV1{Proto: PipelineAttemptRequestProtoV1, ProjectDir: "/x"},
			want: "empty stage order",
		},
		{
			name: "unknown stage in order",
			req: &PipelineAttemptRequestV1{
				Proto:      PipelineAttemptRequestProtoV1,
				Order:      []string{StageCoder, "frob"},
				ProjectDir: "/x",
			},
			want: "not a known stage",
		},
		{
			name: "missing proto",
			req: &PipelineAttemptRequestV1{
				Order:      []string{StageCoder},
				ProjectDir: "/x",
			},
			want: "missing proto",
		},
		{
			name: "negative review cycle",
			req: &PipelineAttemptRequestV1{
				Proto:       PipelineAttemptRequestProtoV1,
				Order:       []string{StageCoder},
				ReviewCycle: -1,
				ProjectDir:  "/x",
			},
			want: "review_cycle",
		},
		{
			name: "negative build_attempt",
			req: &PipelineAttemptRequestV1{
				Proto:        PipelineAttemptRequestProtoV1,
				Order:        []string{StageCoder},
				BuildAttempt: -1,
				ProjectDir:   "/x",
			},
			want: "build_attempt",
		},
		{
			name: "negative max_review_cycles",
			req: &PipelineAttemptRequestV1{
				Proto:           PipelineAttemptRequestProtoV1,
				Order:           []string{StageCoder},
				MaxReviewCycles: -1,
				ProjectDir:      "/x",
			},
			want: "max_review_cycles",
		},
		{
			name: "negative max_build_retries",
			req: &PipelineAttemptRequestV1{
				Proto:           PipelineAttemptRequestProtoV1,
				Order:           []string{StageCoder},
				MaxBuildRetries: -1,
				ProjectDir:      "/x",
			},
			want: "max_build_retries",
		},
		{
			name: "missing project_dir",
			req: &PipelineAttemptRequestV1{
				Proto: PipelineAttemptRequestProtoV1,
				Order: []string{StageCoder},
			},
			want: "project_dir",
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
			if !errors.Is(err, ErrInvalidPipelineRequest) {
				t.Fatalf("error is not ErrInvalidPipelineRequest: %v", err)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error %q does not contain %q", err.Error(), tc.want)
			}
		})
	}
}

func TestPipelineRequestMarshalIndented(t *testing.T) {
	in := &PipelineAttemptRequestV1{
		Proto:           PipelineAttemptRequestProtoV1,
		Task:            "implement feature",
		Milestone:       "m18",
		Order:           []string{StageCoder, StageReview, StageTester},
		ReviewCycle:     1,
		BuildAttempt:    0,
		MaxReviewCycles: 3,
		MaxBuildRetries: 2,
		ProjectDir:      "/tmp/proj",
	}
	b, err := in.MarshalIndented()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	out := &PipelineAttemptRequestV1{}
	if err := json.Unmarshal(b, out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.Proto != PipelineAttemptRequestProtoV1 {
		t.Fatalf("proto lost: %q", out.Proto)
	}
	if out.Task != in.Task || out.Milestone != in.Milestone {
		t.Fatalf("task/milestone lost: got task=%q milestone=%q", out.Task, out.Milestone)
	}
	if len(out.Order) != 3 || out.Order[0] != StageCoder {
		t.Fatalf("order lost: %v", out.Order)
	}
	if out.MaxReviewCycles != 3 || out.MaxBuildRetries != 2 {
		t.Fatalf("limits lost: max_review=%d max_build=%d", out.MaxReviewCycles, out.MaxBuildRetries)
	}
}

func TestPipelineEnsureProto(t *testing.T) {
	req := &PipelineAttemptRequestV1{}
	req.EnsureProto()
	if req.Proto != PipelineAttemptRequestProtoV1 {
		t.Fatalf("request EnsureProto failed: %q", req.Proto)
	}
	res := &PipelineAttemptResultV1{}
	res.EnsureProto()
	if res.Proto != PipelineAttemptResultProtoV1 {
		t.Fatalf("result EnsureProto failed: %q", res.Proto)
	}
}

func TestPipelineRoundTrip(t *testing.T) {
	in := &PipelineAttemptResultV1{
		Proto:   PipelineAttemptResultProtoV1,
		Outcome: AttemptOutcomeSuccess,
		Verdict: VerdictPass,
		Stages: []StageBreakdown{
			{Stage: StageCoder, Verdict: VerdictPass, AgentCalls: 1, DurationSec: 10},
			{Stage: StageReview, Verdict: VerdictRework, NextAction: "rework", ReviewCycle: 1},
			{Stage: StageReview, Verdict: VerdictPass, ReviewCycle: 2},
		},
		AgentCalls:  4,
		DurationSec: 60,
	}
	b, err := in.MarshalIndented()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	out := &PipelineAttemptResultV1{}
	if err := json.Unmarshal(b, out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(out.Stages) != 3 {
		t.Fatalf("stages count mismatch: got %d want 3", len(out.Stages))
	}
	if out.Stages[1].NextAction != "rework" {
		t.Fatalf("next_action lost: %q", out.Stages[1].NextAction)
	}
}
