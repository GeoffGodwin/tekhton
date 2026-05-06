package supervisor

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestAgentError_Is_MatchesOnCategorySubcategoryOnly(t *testing.T) {
	live := &AgentError{
		Category:    "UPSTREAM",
		Subcategory: "api_rate_limit",
		Transient:   true,
		Wrapped:     errors.New("HTTP 429"),
	}
	if !errors.Is(live, ErrUpstreamRateLimit) {
		t.Errorf("errors.Is(live, sentinel) = false; want true (matches Category+Subcategory)")
	}
	if errors.Is(live, ErrUpstream500) {
		t.Errorf("errors.Is should not match different subcategory")
	}
}

func TestAgentError_Is_TransientFlagDoesNotParticipate(t *testing.T) {
	// Sentinel says Transient: true; live has Transient: false; should still match.
	live := &AgentError{Category: "UPSTREAM", Subcategory: "api_rate_limit", Transient: false}
	if !errors.Is(live, ErrUpstreamRateLimit) {
		t.Errorf("Transient flag should not affect identity match")
	}
}

func TestAgentError_Unwrap_ReturnsCause(t *testing.T) {
	cause := errors.New("inner")
	e := &AgentError{Category: "UPSTREAM", Subcategory: "api_rate_limit", Wrapped: cause}
	if !errors.Is(e, cause) {
		t.Errorf("errors.Is via Unwrap chain should be true")
	}
	if got := errors.Unwrap(e); got != cause {
		t.Errorf("Unwrap = %v; want cause", got)
	}
}

func TestAgentError_Error_FormatMatchesV3WireShape(t *testing.T) {
	cause := errors.New("HTTP 429")
	e := &AgentError{Category: "UPSTREAM", Subcategory: "api_rate_limit", Transient: true, Wrapped: cause}
	got := e.Error()
	parts := strings.Split(got, "|")
	if len(parts) != 4 {
		t.Fatalf("Error() = %q; want 4 pipe-delimited parts", got)
	}
	if parts[0] != "UPSTREAM" || parts[1] != "api_rate_limit" || parts[2] != "true" || parts[3] != "HTTP 429" {
		t.Errorf("Error() = %q; want UPSTREAM|api_rate_limit|true|HTTP 429", got)
	}
}

func TestAgentError_Error_NoWrappedYieldsEmptyMessage(t *testing.T) {
	e := &AgentError{Category: "ENVIRONMENT", Subcategory: "oom", Transient: true}
	got := e.Error()
	if got != "ENVIRONMENT|oom|true|" {
		t.Errorf("Error() = %q; want ENVIRONMENT|oom|true|", got)
	}
}

// Every sentinel in the taxonomy should match a freshly-built live error with
// the same Category+Subcategory regardless of Transient or Wrapped.
func TestSentinelTaxonomy_AllSentinelsMatchSelf(t *testing.T) {
	sentinels := []*AgentError{
		ErrUpstreamRateLimit, ErrUpstreamOverloaded, ErrUpstream500, ErrUpstreamAuth,
		ErrUpstreamTimeout, ErrUpstreamUnknown, ErrQuotaExhausted,
		ErrEnvOOM, ErrEnvNetwork, ErrEnvDiskFull, ErrEnvMissingDep, ErrEnvPermissions, ErrEnvUnknown,
		ErrAgentNullRun, ErrAgentMaxTurns, ErrAgentActivityTimeout, ErrAgentNullActivityTimeout,
		ErrAgentNoSummary, ErrAgentScopeUnknown,
		ErrPipelineStateCorrupt, ErrPipelineConfigError, ErrPipelineMissingFile,
		ErrPipelineTemplateError, ErrPipelineInternal,
	}
	for _, s := range sentinels {
		live := &AgentError{
			Category:    s.Category,
			Subcategory: s.Subcategory,
			Transient:   !s.Transient,
			Wrapped:     errors.New("anything"),
		}
		if !errors.Is(live, s) {
			t.Errorf("%s|%s: live should match sentinel via errors.Is", s.Category, s.Subcategory)
		}
	}
}

func TestErrFatalAgent_AliasesScopeUnknown(t *testing.T) {
	if !errors.Is(ErrFatalAgent, ErrAgentScopeUnknown) {
		t.Errorf("ErrFatalAgent should alias ErrAgentScopeUnknown")
	}
}

func TestClassifyResult_NilSafe(t *testing.T) {
	if err := classifyResult(nil); err != nil {
		t.Errorf("classifyResult(nil) = %v; want nil", err)
	}
}

func TestClassifyResult_SuccessReturnsNil(t *testing.T) {
	r := &proto.AgentResultV1{Outcome: proto.OutcomeSuccess}
	if err := classifyResult(r); err != nil {
		t.Errorf("classifyResult(success) = %v; want nil", err)
	}
}

func TestClassifyResult_TurnExhaustedReturnsNil(t *testing.T) {
	r := &proto.AgentResultV1{Outcome: proto.OutcomeTurnExhausted}
	if err := classifyResult(r); err != nil {
		t.Errorf("classifyResult(turn_exhausted) = %v; want nil", err)
	}
}

func TestClassifyResult_MapsByErrorCategory(t *testing.T) {
	cases := []struct {
		cat, sub string
		sentinel *AgentError
	}{
		{"UPSTREAM", "api_rate_limit", ErrUpstreamRateLimit},
		{"UPSTREAM", "api_overloaded", ErrUpstreamOverloaded},
		{"UPSTREAM", "api_500", ErrUpstream500},
		{"UPSTREAM", "api_auth", ErrUpstreamAuth},
		{"UPSTREAM", "api_timeout", ErrUpstreamTimeout},
		{"UPSTREAM", "api_unknown", ErrUpstreamUnknown},
		{"UPSTREAM", "quota_exhausted", ErrQuotaExhausted},
		{"ENVIRONMENT", "oom", ErrEnvOOM},
		{"ENVIRONMENT", "network", ErrEnvNetwork},
		{"ENVIRONMENT", "disk_full", ErrEnvDiskFull},
		{"AGENT_SCOPE", "null_run", ErrAgentNullRun},
		{"AGENT_SCOPE", "max_turns", ErrAgentMaxTurns},
		{"AGENT_SCOPE", "activity_timeout", ErrAgentActivityTimeout},
		{"PIPELINE", "internal", ErrPipelineInternal},
	}
	for _, tc := range cases {
		t.Run(tc.cat+"_"+tc.sub, func(t *testing.T) {
			r := &proto.AgentResultV1{
				Outcome:          proto.OutcomeFatalError,
				ErrorCategory:    tc.cat,
				ErrorSubcategory: tc.sub,
			}
			err := classifyResult(r)
			if !errors.Is(err, tc.sentinel) {
				t.Errorf("classifyResult({%s, %s}) = %v; want errors.Is %s|%s",
					tc.cat, tc.sub, err, tc.sentinel.Category, tc.sentinel.Subcategory)
			}
		})
	}
}

func TestClassifyResult_PropagatesTransientFlag(t *testing.T) {
	r := &proto.AgentResultV1{
		Outcome:          proto.OutcomeFatalError,
		ErrorCategory:    "UPSTREAM",
		ErrorSubcategory: "api_rate_limit",
		ErrorTransient:   true,
	}
	err := classifyResult(r)
	var ae *AgentError
	if !errors.As(err, &ae) {
		t.Fatalf("errors.As: expected *AgentError, got %T", err)
	}
	if !ae.Transient {
		t.Errorf("Transient: got false, want true")
	}
}

func TestClassifyResult_FallsBackOnActivityTimeoutOutcome(t *testing.T) {
	r := &proto.AgentResultV1{Outcome: proto.OutcomeActivityTimeout}
	err := classifyResult(r)
	if !errors.Is(err, ErrAgentActivityTimeout) {
		t.Errorf("activity_timeout outcome should classify as ErrAgentActivityTimeout, got %v", err)
	}
}

func TestClassifyResult_FallsBackOnFatalErrorOutcome(t *testing.T) {
	r := &proto.AgentResultV1{Outcome: proto.OutcomeFatalError, ErrorMessage: "boom"}
	err := classifyResult(r)
	if !errors.Is(err, ErrFatalAgent) {
		t.Errorf("fatal_error with no fields should map to ErrFatalAgent, got %v", err)
	}
	// And the message should be wrapped so callers can errors.Unwrap to recover it.
	if got := fmt.Sprintf("%v", errors.Unwrap(err)); got != "boom" {
		t.Errorf("unwrapped message: got %q, want %q", got, "boom")
	}
}

func TestClassifyResult_FallsBackOnTransientErrorOutcome(t *testing.T) {
	r := &proto.AgentResultV1{Outcome: proto.OutcomeTransientError, ErrorMessage: "rate limited"}
	err := classifyResult(r)
	if !errors.Is(err, ErrUpstreamUnknown) {
		t.Errorf("transient_error outcome with no ErrorCategory/Subcategory should map to ErrUpstreamUnknown, got %v", err)
	}
	// ErrorMessage should be wrapped so callers can recover it.
	if got := fmt.Sprintf("%v", errors.Unwrap(err)); got != "rate limited" {
		t.Errorf("unwrapped message: got %q, want %q", got, "rate limited")
	}
}
