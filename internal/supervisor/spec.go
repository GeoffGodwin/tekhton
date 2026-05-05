package supervisor

import (
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// AgentSpec is the Go-idiomatic input shape to Run. Wire callers (CLI, future
// in-process callers) hold AgentRequestV1 directly; in-process Go code that
// builds requests structurally is friendlier with time.Duration than raw
// seconds, hence this thin wrapper. ToProto is the one-way conversion the
// supervisor uses internally before validation.
type AgentSpec struct {
	RunID           string
	Label           string
	Model           string
	MaxTurns        int
	PromptFile      string
	WorkingDir      string
	Timeout         time.Duration
	ActivityTimeout time.Duration
	Env             map[string]string
}

// ToProto converts an AgentSpec to the wire envelope. Durations round to
// whole seconds — sub-second precision was never part of the V3 contract,
// and the JSON envelope uses *_secs field names accordingly.
func (s *AgentSpec) ToProto() *proto.AgentRequestV1 {
	if s == nil {
		return nil
	}
	return &proto.AgentRequestV1{
		Proto:               proto.AgentRequestProtoV1,
		RunID:               s.RunID,
		Label:               s.Label,
		Model:               s.Model,
		MaxTurns:            s.MaxTurns,
		PromptFile:          s.PromptFile,
		WorkingDir:          s.WorkingDir,
		TimeoutSecs:         int(s.Timeout / time.Second),
		ActivityTimeoutSecs: int(s.ActivityTimeout / time.Second),
		EnvOverrides:        s.Env,
	}
}

// AgentResult is the Go-idiomatic output shape — DurationMs becomes a
// time.Duration. Mirrors AgentSpec.
type AgentResult struct {
	RunID            string
	Label            string
	ExitCode         int
	TurnsUsed        int
	Duration         time.Duration
	Outcome          string
	ErrorCategory    string
	ErrorSubcategory string
	ErrorTransient   bool
	ErrorMessage     string
	LastEventID      string
	StdoutTail       []string
}

// FromProto converts the wire envelope to AgentResult. Callers reading off
// the supervisor result use this to escape from raw int milliseconds into
// time.Duration.
func FromProto(p *proto.AgentResultV1) *AgentResult {
	if p == nil {
		return nil
	}
	return &AgentResult{
		RunID:            p.RunID,
		Label:            p.Label,
		ExitCode:         p.ExitCode,
		TurnsUsed:        p.TurnsUsed,
		Duration:         time.Duration(p.DurationMs) * time.Millisecond,
		Outcome:          p.Outcome,
		ErrorCategory:    p.ErrorCategory,
		ErrorSubcategory: p.ErrorSubcategory,
		ErrorTransient:   p.ErrorTransient,
		ErrorMessage:     p.ErrorMessage,
		LastEventID:      p.LastEventID,
		StdoutTail:       p.StdoutTail,
	}
}

// V3 error vocabulary. These constants are the single source of truth for
// the ErrorCategory string the supervisor stamps on a result. They mirror
// lib/errors.sh's `echo "<CATEGORY>|<SUBCATEGORY>|<TRANSIENT>|<MESSAGE>"`
// records exactly. Renaming any of these is a breaking wire change — the
// causal log query layer and any external dashboard consumer reads the
// string form.
const (
	CategoryUpstream    = "UPSTREAM"
	CategoryEnvironment = "ENVIRONMENT"
	CategoryAgentScope  = "AGENT_SCOPE"
	CategoryPipeline    = "PIPELINE"
)

// V3 subcategory vocabulary for CategoryUpstream. Subset reproduced from
// lib/errors.sh; m06 fills in the remaining call sites as the real subprocess
// path lands. The transient flag matches V3 semantics — true means the
// retry envelope (m07) should retry, false means escalate to the human.
const (
	SubcatAPIRateLimit  = "api_rate_limit"
	SubcatAPIOverloaded = "api_overloaded"
	SubcatAPI500        = "api_500"
	SubcatAPIAuth       = "api_auth"
	SubcatAPITimeout    = "api_timeout"
	SubcatAPIUnknown    = "api_unknown"
)

// V3 subcategory vocabulary for CategoryEnvironment.
const (
	SubcatOOM         = "oom"
	SubcatDiskFull    = "disk_full"
	SubcatNetwork     = "network"
	SubcatMissingDep  = "missing_dep"
	SubcatPermissions = "permissions"
	SubcatEnvUnknown  = "env_unknown"
)

// CategoryTransient reports whether a (category, subcategory) pair is
// classed transient by the V3 vocabulary. This is the table m07's retry
// envelope will consult; for m05 it exists so the proto package can stay
// pure-types and the mapping has a deterministic home.
//
// Unknown categories return false (conservative — don't auto-retry the
// unrecognized).
func CategoryTransient(category, subcategory string) bool {
	switch category {
	case CategoryUpstream:
		switch subcategory {
		case SubcatAPIAuth:
			return false
		default:
			return true
		}
	case CategoryEnvironment:
		switch subcategory {
		case SubcatOOM, SubcatNetwork:
			return true
		default:
			return false
		}
	}
	return false
}
