// Package diagnose owns the m32 Go-native port of the Tekhton diagnostic
// engine. m32.1 lands the engine framework + helpers + Rule/Diagnosis
// contracts; m32.2 will land a Go-native rule registry; m32.3 will land the
// output writers + dashboard emitter + crash first-aid and delete the bash
// surface entirely.
//
// During the m32.1 transition window, the engine drives the legacy bash rule
// registry through BashRuleAdapter so observable behavior matches v4.31.x
// byte-for-byte. The seam is the Rule interface — m32.2 swaps the adapter
// for a native rule registry without touching Engine.Run.
package diagnose

// Confidence is the qualitative certainty band a rule attaches to its match.
// Mirrors the bash $DIAG_CONFIDENCE vocabulary (high|medium|low).
type Confidence string

const (
	// ConfidenceHigh — rule matched on a load-bearing, unambiguous signal.
	ConfidenceHigh Confidence = "high"
	// ConfidenceMedium — rule matched on a strong but heuristic signal.
	ConfidenceMedium Confidence = "medium"
	// ConfidenceLow — rule matched as a fallback / unknown-class catch-all.
	ConfidenceLow Confidence = "low"
)

// RecurringInfo carries the per-classification recurrence stats produced by
// Helpers.DetectRecurring. Count==0 means "not recurring" (the bash zero
// state); Note is set only when Count >= 3 (the bash escalation threshold).
type RecurringInfo struct {
	Count int
	Note  string
}

// Diagnosis is the engine's structured verdict. It is the return value of
// Engine.Run and the input to the (m32.3) output writers.
//
// Classification is the rule-name vocabulary (BUILD_FAILURE, MAX_TURNS_EXHAUSTED,
// etc.) that downstream consumers — Watchtower dashboard, RUN_SUMMARY enrichers,
// recurring-failure escalation — switch on. Confidence drives operator UI
// styling. Stage names the pipeline stage where the failure landed. Suggestions
// is the operator-facing recovery hint list (first element doubles as the
// summary banner; remaining elements are the numbered options block).
//
// RuleName carries the bash function name of the matched rule (e.g.
// "_rule_max_turns") so the engine can emit the byte-identical
// `[diag] rule=NAME confidence=LEVEL classification=CLASS stage=STAGE` one-liner
// the bash parity gate asserts on.
type Diagnosis struct {
	Classification string
	Confidence     Confidence
	Stage          string
	Suggestions    []string
	Recurring      RecurringInfo
	CauseChain     string
	RuleName       string
}

// Context is the aggregated, structured snapshot of the four pipeline state
// inputs the engine reads (PIPELINE_STATE.md, RUN_SUMMARY.json,
// LAST_FAILURE_CONTEXT.json, CAUSAL_LOG.jsonl). It replaces the bash
// _DIAG_* module-state globals — the field set here MUST be a strict
// superset of the bash globals enumerated in lib/diagnose.sh:46-73.
//
// Rules receive this struct by pointer and must NOT mutate it; Engine.Run
// passes the same *Context to each rule in priority order.
type Context struct {
	ProjectDir  string
	TekhtonHome string

	// Aggregated outcome / location fields.
	Outcome        string // success | failure | timeout | stuck | ""
	Stage          string
	Task           string
	Milestone      string
	ExitReason     string
	Classification string // last-run classification from LAST_FAILURE_CONTEXT
	SchemaVersion  int    // LAST_FAILURE_CONTEXT schema_version (0 when absent)

	// M129 nested cause slots — populated by the v2 cause-block reader.
	PrimaryCategory      string
	PrimarySubcategory   string
	PrimarySignal        string
	PrimarySource        string
	SecondaryCategory    string
	SecondarySubcategory string
	SecondarySignal      string
	SecondarySource      string

	// Causal log aggregates.
	CausalEvents    string // raw JSONL content, line-joined
	TerminalEvent   string // last line of the log
	ErrorEvents     string // grep of `"type":"error"` lines
	ReviewCycles    int    // verdict events with stage=reviewer
	CauseChain      string // pre-collapse cause chain
	CauseChainShort string // collapsed cause chain (max 5 links)

	// Migration detection.
	MigrationBackups []string // paths under MIGRATION_BACKUP_DIR/pre-*

	// Build-error artifact presence used by both core and resilience rules.
	BuildErrorsFile    string
	BuildRawErrorsFile string
	BuildFixReportFile string

	// Agent log tails — map of basename -> last 20 lines.
	AgentLogTails map[string]string
}

// Rule is the m32.1 seam between the engine and the rule registry. m32.1 ships
// a BashRuleAdapter that wraps each legacy bash rule function in this
// interface; m32.2 replaces the adapter with native Go implementations.
//
// Match is expected to be side-effect free with respect to *Context: rules
// read but must not mutate. A return of (Diagnosis{}, false) means "no
// match" and the engine falls through to the next rule; (Diagnosis{...}, true)
// means "matched, use this verdict" and the engine stops.
type Rule interface {
	Name() string
	Match(c *Context) (Diagnosis, bool)
}

// RuleProvider exposes the priority-ordered rule list to the engine. The
// engine walks Rules() top-down and stops at the first Match returning true.
// During m32.1 the only implementation is BashRuleAdapter; m32.2 lands the
// native Registry.
type RuleProvider interface {
	Rules() []Rule
}
