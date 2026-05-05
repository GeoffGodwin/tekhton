package proto

import (
	"errors"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Validate — AC #2 (request envelope validation)
// ---------------------------------------------------------------------------

func TestAgentRequestV1_Validate_Valid(t *testing.T) {
	r := &AgentRequestV1{
		Proto:      AgentRequestProtoV1,
		Label:      "coder",
		Model:      "claude-opus-4-7",
		PromptFile: "/tmp/coder.prompt",
	}
	if err := r.Validate(); err != nil {
		t.Errorf("valid request rejected: %v", err)
	}
}

func TestAgentRequestV1_Validate_NilReceiver(t *testing.T) {
	var r *AgentRequestV1
	err := r.Validate()
	if err == nil {
		t.Fatal("expected error for nil receiver, got nil")
	}
	if !errors.Is(err, ErrInvalidRequest) {
		t.Errorf("error not wrapped in ErrInvalidRequest: %v", err)
	}
}

func TestAgentRequestV1_Validate_RejectsMissingFields(t *testing.T) {
	cases := []struct {
		name    string
		req     AgentRequestV1
		wantSub string
	}{
		{
			name:    "missing proto",
			req:     AgentRequestV1{Label: "coder", Model: "m", PromptFile: "/p"},
			wantSub: "missing proto",
		},
		{
			name:    "wrong proto version",
			req:     AgentRequestV1{Proto: "tekhton.agent.request.v999", Label: "c", Model: "m", PromptFile: "/p"},
			wantSub: "wrong proto",
		},
		{
			name:    "missing label",
			req:     AgentRequestV1{Proto: AgentRequestProtoV1, Model: "m", PromptFile: "/p"},
			wantSub: "missing label",
		},
		{
			name:    "missing model",
			req:     AgentRequestV1{Proto: AgentRequestProtoV1, Label: "c", PromptFile: "/p"},
			wantSub: "missing model",
		},
		{
			name:    "missing prompt_file",
			req:     AgentRequestV1{Proto: AgentRequestProtoV1, Label: "c", Model: "m"},
			wantSub: "missing prompt_file",
		},
		{
			name:    "negative max_turns",
			req:     AgentRequestV1{Proto: AgentRequestProtoV1, Label: "c", Model: "m", PromptFile: "/p", MaxTurns: -1},
			wantSub: "max_turns",
		},
		{
			name:    "negative timeout_secs",
			req:     AgentRequestV1{Proto: AgentRequestProtoV1, Label: "c", Model: "m", PromptFile: "/p", TimeoutSecs: -1},
			wantSub: "timeout_secs",
		},
		{
			name:    "negative activity_timeout_secs",
			req:     AgentRequestV1{Proto: AgentRequestProtoV1, Label: "c", Model: "m", PromptFile: "/p", ActivityTimeoutSecs: -1},
			wantSub: "activity_timeout_secs",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.req.Validate()
			if err == nil {
				t.Fatal("expected error, got nil")
			}
			if !errors.Is(err, ErrInvalidRequest) {
				t.Errorf("error not wrapped in ErrInvalidRequest: %v", err)
			}
			if !strings.Contains(err.Error(), tc.wantSub) {
				t.Errorf("error message %q does not contain %q", err.Error(), tc.wantSub)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// EnsureProto / TrimStdoutTail
// ---------------------------------------------------------------------------

func TestAgentRequestV1_EnsureProto(t *testing.T) {
	r := &AgentRequestV1{}
	r.EnsureProto()
	if r.Proto != AgentRequestProtoV1 {
		t.Errorf("EnsureProto: got %q, want %q", r.Proto, AgentRequestProtoV1)
	}
	r.Proto = "custom"
	r.EnsureProto()
	if r.Proto != "custom" {
		t.Errorf("EnsureProto must not overwrite existing proto, got %q", r.Proto)
	}
}

func TestAgentResultV1_EnsureProto(t *testing.T) {
	r := &AgentResultV1{}
	r.EnsureProto()
	if r.Proto != AgentResultProtoV1 {
		t.Errorf("EnsureProto: got %q, want %q", r.Proto, AgentResultProtoV1)
	}
}

func TestAgentResultV1_TrimStdoutTail_NoOpUnderCap(t *testing.T) {
	r := &AgentResultV1{StdoutTail: []string{"a", "b", "c"}}
	r.TrimStdoutTail()
	if len(r.StdoutTail) != 3 {
		t.Errorf("under-cap tail trimmed: len=%d", len(r.StdoutTail))
	}
}

func TestAgentResultV1_TrimStdoutTail_TrimsOverCap(t *testing.T) {
	tail := make([]string, StdoutTailMaxLines+10)
	for i := range tail {
		tail[i] = string(rune('a' + (i % 26)))
	}
	r := &AgentResultV1{StdoutTail: tail}
	r.TrimStdoutTail()
	if len(r.StdoutTail) != StdoutTailMaxLines {
		t.Errorf("trim len: got %d, want %d", len(r.StdoutTail), StdoutTailMaxLines)
	}
	// The retained slice must be the LAST StdoutTailMaxLines lines — the
	// ring-buffer semantics from V3.
	if r.StdoutTail[len(r.StdoutTail)-1] != tail[len(tail)-1] {
		t.Errorf("last line lost: got %q, want %q", r.StdoutTail[len(r.StdoutTail)-1], tail[len(tail)-1])
	}
}

func TestAgentResultV1_TrimStdoutTail_NilSafe(t *testing.T) {
	r := &AgentResultV1{} // StdoutTail nil
	r.TrimStdoutTail()
	if r.StdoutTail != nil {
		t.Errorf("nil tail mutated: %v", r.StdoutTail)
	}
}
