package proto

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestAttemptRequestValidate(t *testing.T) {
	cases := []struct {
		name    string
		req     *AttemptRequestV1
		wantErr bool
	}{
		{
			name:    "nil",
			req:     nil,
			wantErr: true,
		},
		{
			name:    "missing proto",
			req:     &AttemptRequestV1{Task: "x", ProjectDir: "/tmp"},
			wantErr: true,
		},
		{
			name:    "wrong proto",
			req:     &AttemptRequestV1{Proto: "tekhton.attempt.request.v2", Task: "x", ProjectDir: "/tmp"},
			wantErr: true,
		},
		{
			name:    "missing task",
			req:     &AttemptRequestV1{Proto: AttemptRequestProtoV1, ProjectDir: "/tmp"},
			wantErr: true,
		},
		{
			name:    "missing project_dir",
			req:     &AttemptRequestV1{Proto: AttemptRequestProtoV1, Task: "x"},
			wantErr: true,
		},
		{
			name:    "negative max_pipeline_attempts",
			req:     &AttemptRequestV1{Proto: AttemptRequestProtoV1, Task: "x", ProjectDir: "/tmp", MaxPipelineAttempts: -1},
			wantErr: true,
		},
		{
			name:    "negative autonomous_timeout_secs",
			req:     &AttemptRequestV1{Proto: AttemptRequestProtoV1, Task: "x", ProjectDir: "/tmp", AutonomousTimeoutSecs: -1},
			wantErr: true,
		},
		{
			name:    "negative max_autonomous_agent_calls",
			req:     &AttemptRequestV1{Proto: AttemptRequestProtoV1, Task: "x", ProjectDir: "/tmp", MaxAutonomousAgentCalls: -1},
			wantErr: true,
		},
		{
			name: "valid",
			req: &AttemptRequestV1{
				Proto:      AttemptRequestProtoV1,
				Task:       "Implement Milestone 12",
				ProjectDir: "/tmp/proj",
			},
			wantErr: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.req.Validate()
			gotErr := err != nil
			if gotErr != tc.wantErr {
				t.Fatalf("Validate() err=%v; wantErr=%v", err, tc.wantErr)
			}
			if tc.wantErr && err != nil && !errors.Is(err, ErrInvalidAttemptRequest) {
				t.Fatalf("Validate() err=%v; want errors.Is ErrInvalidAttemptRequest", err)
			}
		})
	}
}

func TestEnsureProtoStampsRequestAndResult(t *testing.T) {
	req := &AttemptRequestV1{Task: "x", ProjectDir: "/tmp"}
	req.EnsureProto()
	if req.Proto != AttemptRequestProtoV1 {
		t.Fatalf("request Proto = %q; want %q", req.Proto, AttemptRequestProtoV1)
	}

	res := &AttemptResultV1{Outcome: AttemptOutcomeSuccess}
	res.EnsureProto()
	if res.Proto != AttemptResultProtoV1 {
		t.Fatalf("result Proto = %q; want %q", res.Proto, AttemptResultProtoV1)
	}

	// Idempotent: ensure does not overwrite a non-empty proto.
	req2 := &AttemptRequestV1{Proto: "preset", Task: "x", ProjectDir: "/tmp"}
	req2.EnsureProto()
	if req2.Proto != "preset" {
		t.Fatalf("EnsureProto overwrote preset value: %q", req2.Proto)
	}
}

func TestMarshalIndentedRoundTrip(t *testing.T) {
	res := &AttemptResultV1{
		Proto:       AttemptResultProtoV1,
		RunID:       "r-12345",
		Outcome:     AttemptOutcomeSuccess,
		Attempts:    2,
		AgentCalls:  7,
		ElapsedSecs: 312,
		TotalTurns:  84,
	}
	b, err := res.MarshalIndented()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(b), `"proto": "tekhton.attempt.result.v1"`) {
		t.Fatalf("marshal output missing proto tag: %s", b)
	}
	var rt AttemptResultV1
	if err := json.Unmarshal(b, &rt); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if rt.RunID != res.RunID || rt.Attempts != res.Attempts {
		t.Fatalf("round-trip mismatch: got %+v", rt)
	}

	req := &AttemptRequestV1{
		Proto:      AttemptRequestProtoV1,
		Task:       "x",
		ProjectDir: "/tmp",
	}
	rb, err := req.MarshalIndented()
	if err != nil {
		t.Fatalf("request marshal: %v", err)
	}
	if !strings.Contains(string(rb), `"proto": "tekhton.attempt.request.v1"`) {
		t.Fatalf("request marshal missing proto tag: %s", rb)
	}
}
