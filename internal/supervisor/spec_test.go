package supervisor

import "testing"

func TestIsNullRun(t *testing.T) {
	tests := []struct {
		name string
		r    *AgentResult
		want bool
	}{
		{"nil result", nil, true},
		{"zero turns", &AgentResult{TurnsUsed: 0}, true},
		{"non-zero exit, turns under threshold", &AgentResult{ExitCode: 1, TurnsUsed: 1}, true},
		{"non-zero exit, turns at threshold", &AgentResult{ExitCode: 1, TurnsUsed: DefaultNullRunThreshold}, true},
		{"non-zero exit, turns above threshold", &AgentResult{ExitCode: 1, TurnsUsed: DefaultNullRunThreshold + 1}, false},
		{"zero exit, turns above zero", &AgentResult{ExitCode: 0, TurnsUsed: 1}, false},
		{"zero exit, many turns", &AgentResult{ExitCode: 0, TurnsUsed: 50}, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.r.IsNullRun(); got != tc.want {
				t.Errorf("IsNullRun() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestIsNullRunAt_CustomThreshold(t *testing.T) {
	// With threshold 5, a non-zero exit at TurnsUsed=4 is still a null run.
	r := &AgentResult{ExitCode: 1, TurnsUsed: 4}
	if !r.IsNullRunAt(5) {
		t.Errorf("IsNullRunAt(5) = false, want true for exit=1 turns=4")
	}
	if r.IsNullRunAt(3) {
		t.Errorf("IsNullRunAt(3) = true, want false for exit=1 turns=4")
	}
}
