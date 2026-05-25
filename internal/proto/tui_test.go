package proto

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestTUIStatusV1RoundTrip(t *testing.T) {
	verdict := "PASS"
	env := TUIStatusV1Envelope{
		Proto: TUIStatusV1,
		RunID: "20260525_100000",
		Payload: TUIStatusV1Payload{
			Version:     1,
			RunID:       "20260525_100000",
			Milestone:   "m23",
			Task:        "TUI ops port",
			Attempt:     1,
			MaxAttempts: 3,
			StageNum:    2,
			StageTotal:  7,
			StageLabel:  "Coder",
			StagesComplete: []TUIStageEntry{
				{Label: "Intake", LifecycleID: "intake#1", Model: "claude-opus", Turns: "5/20", Time: "01:23", Verdict: &verdict},
			},
			RecentEvents: []TUIEventEntry{
				{TS: "12:34:56", Level: "info", Type: "runtime", Msg: "started"},
			},
			StageOrder: []string{"intake", "coder", "review", "tester"},
		},
	}

	b, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var got TUIStatusV1Envelope
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.Proto != TUIStatusV1 {
		t.Errorf("proto: got %q, want %q", got.Proto, TUIStatusV1)
	}
	if got.RunID != "20260525_100000" {
		t.Errorf("run_id: got %q", got.RunID)
	}
	if got.Payload.Milestone != "m23" {
		t.Errorf("milestone: got %q", got.Payload.Milestone)
	}
	if len(got.Payload.StagesComplete) != 1 {
		t.Fatalf("stages_complete: got %d entries", len(got.Payload.StagesComplete))
	}
	if got.Payload.StagesComplete[0].LifecycleID != "intake#1" {
		t.Errorf("stage lifecycle_id: got %q", got.Payload.StagesComplete[0].LifecycleID)
	}
}

func TestTUIStatusV1Validate(t *testing.T) {
	cases := []struct {
		name    string
		env     *TUIStatusV1Envelope
		wantErr string
	}{
		{name: "nil", env: nil, wantErr: "nil envelope"},
		{name: "missing proto", env: &TUIStatusV1Envelope{}, wantErr: "missing proto"},
		{name: "wrong proto", env: &TUIStatusV1Envelope{Proto: "tekhton.tui.status.v2"}, wantErr: "wrong proto"},
		{name: "valid", env: &TUIStatusV1Envelope{Proto: TUIStatusV1}, wantErr: ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.env.Validate()
			if tc.wantErr == "" {
				if err != nil {
					t.Errorf("unexpected error: %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tc.wantErr)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("error: got %q, want substring %q", err.Error(), tc.wantErr)
			}
		})
	}
}

func TestTUIStatusV1EnsureProto(t *testing.T) {
	e := &TUIStatusV1Envelope{}
	e.EnsureProto()
	if e.Proto != TUIStatusV1 {
		t.Errorf("ensure: got %q, want %q", e.Proto, TUIStatusV1)
	}
	e.Proto = "custom"
	e.EnsureProto()
	if e.Proto != "custom" {
		t.Errorf("ensure should not overwrite: got %q", e.Proto)
	}
}
