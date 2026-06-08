// Package scout implements the coder-stage scout sub-agent (m39.3 port).
//
// stages/coder.sh hosts the scout block inline at lines 189-358; m39.3
// ports the orchestrator (Run), the post-scout turn-limit application
// (Apply), and the should-scout predicate (ShouldScout) to Go without
// deleting the bash. The bash version still serves the bash-coder path
// until m39.4 deletes stages/coder.sh together with the build-fix wedge.
//
// The scout's role in the pipeline is to pre-locate the files the coder
// will modify and emit a complexity estimate that drives downstream turn
// budgets (CODER / REVIEWER / TESTER). Empty / null-run scout outputs are
// non-fatal — the coder falls back to filesystem exploration.
package scout

// Estimate holds the parsed Complexity Estimate fields the scout's report
// emits. Zero values for any Recommended* field mean "parse failed" and
// signal Apply to keep the configured default for that role.
//
// Field shape mirrors the bash globals SCOUT_FILES_TO_MODIFY,
// SCOUT_LINES_OF_CHANGE, SCOUT_INTERCONNECTED, SCOUT_REC_*_TURNS.
type Estimate struct {
	FilesToModify       int
	EstimatedLines      int
	Interconnected      string // "low" | "medium" | "high" | "unknown"
	RecommendedCoder    int
	RecommendedReviewer int
	RecommendedTester   int
}

// TurnLimits is the resolved per-stage turn budget triple. Apply produces
// one from an Estimate + floors; the m39.4 orchestrator wires the fields
// into ADJUSTED_CODER_TURNS / ADJUSTED_REVIEWER_TURNS /
// ADJUSTED_TESTER_TURNS at process boundary.
type TurnLimits struct {
	Coder    int
	Reviewer int
	Tester   int
}

// DefaultFloors returns the m39.3-spec floor triple (Coder=15,
// Reviewer=5, Tester=15). The m39.4 orchestrator overrides these with
// the bash-conf values (CODER_MAX_TURNS etc.) so the production floor
// matches stages/coder.sh's behavior; the defaults here serve tests and
// callers that want the documented minimum.
//
// The values are NOT the bash defaults — bash uses 80/20/50. The
// milestone design intentionally introduces a smaller floor so the
// orchestrator can choose whether to enforce the larger configured
// default or the minimum-safe value.
func DefaultFloors() TurnLimits {
	return TurnLimits{Coder: 15, Reviewer: 5, Tester: 15}
}
