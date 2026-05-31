// Diagnosis envelope (m32.1).
//
// DiagnosisV1 is the JSON envelope written to ${DASHBOARD_DIR}/data/diagnosis.js
// (wrapped in `TK_DIAGNOSIS = <json>;`) for the Watchtower dashboard. m32.1
// freezes the wire shape so the m32.3 Go-native dashboard emitter and the
// browser reader (`templates/watchtower/app.js`) round-trip against a single
// typed contract — replacing the bash `emit_dashboard_diagnosis` printf JSON
// it currently produces.
//
// Versioning. Field additions within v1 are additive; renames or removals
// bump the proto tag and ship as DiagnosisV2 alongside V1. The JS reader
// treats missing fields defensively, so additive evolution is safe.
//
// Note. This is distinct from the m33.1 `DashboardDiagnosisV1` stub in
// dashboard_v1_extra.go, which froze a placeholder 4-field shape before
// the engine's full output contract was known. m32.3 will migrate the
// dashboard emitter from the placeholder to this canonical 8-field envelope.

package proto

import (
	"encoding/json"
	"errors"
	"fmt"
)

// DiagnosisV1Proto is the wire identifier for the v1 envelope. The on-disk
// JS data file does not embed this tag (it is wrapped JS, not a typed
// envelope), but the runtime carries it so future variants can be flagged.
const DiagnosisV1Proto = "tekhton.diagnosis.v1"

// DiagnosisV1SchemaVersion is the integer schema_version emitted in the
// JSON payload. m32.1 == 1.
const DiagnosisV1SchemaVersion = 1

// ErrDiagnosisInvalid is the sentinel returned by Validate() when an
// envelope would emit a JS file the reader cannot consume. Wrap with
// fmt.Errorf("%w: ...") so callers can errors.Is against it.
var ErrDiagnosisInvalid = errors.New("diagnosis payload invalid")

// validDiagnosisConfidence is the legal Confidence vocabulary. Empty is
// tolerated for the available=false stub but rejected when Available is true.
var validDiagnosisConfidence = map[string]struct{}{
	"high":   {},
	"medium": {},
	"low":    {},
}

// DiagnosisV1 is the JSON shape written to diagnosis.js. Field order follows
// the bash emit_dashboard_diagnosis printf in lib/diagnose_output_extra.sh:86
// byte-for-byte so the m32.3 parity gate diffs cleanly.
type DiagnosisV1 struct {
	// Available is false when no failure diagnosis exists yet — the file
	// holds the singleton `{"available":false}` shape and all other fields
	// are zero/empty. When true, the engine has produced a verdict and the
	// remaining fields populate.
	Available bool `json:"available"`

	// Classification is the rule-name vocabulary (BUILD_FAILURE,
	// MAX_TURNS_EXHAUSTED, REVIEW_REJECTION_LOOP, ...). Empty when
	// Available is false.
	Classification string `json:"classification,omitempty"`

	// Confidence is the qualitative band (high|medium|low). Empty when
	// Available is false; required when true.
	Confidence string `json:"confidence,omitempty"`

	// Stage is the pipeline stage where the failure landed (coder, reviewer,
	// tester, ...). Empty when not derivable from the input context.
	Stage string `json:"stage,omitempty"`

	// CauseChain is the human-readable collapsed cause chain (max 5 links)
	// produced by Helpers.CollapseCauseChain. Empty when no causal log is
	// present.
	CauseChain string `json:"cause_chain,omitempty"`

	// Suggestions is the operator-facing recovery hint list. The first
	// element doubles as the summary banner; remaining elements form the
	// numbered options block in the dashboard.
	Suggestions []string `json:"suggestions,omitempty"`

	// RecurringCount is the count of consecutive runs that produced the
	// same Classification. Zero when not recurring. The bash zero state
	// is emitted unquoted as a JSON number.
	RecurringCount int `json:"recurring_count"`

	// SchemaVersion is the integer version of this envelope shape.
	// m32.1 == DiagnosisV1SchemaVersion (= 1).
	SchemaVersion int `json:"schema_version"`
}

// Validate enforces the basic invariants: when Available is true,
// Classification and Confidence must be populated; the Confidence
// vocabulary must be one of {high,medium,low}; RecurringCount and
// SchemaVersion must be non-negative.
func (p *DiagnosisV1) Validate() error {
	if p.RecurringCount < 0 {
		return fmt.Errorf("%w: recurring_count=%d must be >= 0", ErrDiagnosisInvalid, p.RecurringCount)
	}
	if p.SchemaVersion < 0 {
		return fmt.Errorf("%w: schema_version=%d must be >= 0", ErrDiagnosisInvalid, p.SchemaVersion)
	}
	if !p.Available {
		return nil
	}
	if p.Classification == "" {
		return fmt.Errorf("%w: classification is required when available=true", ErrDiagnosisInvalid)
	}
	if p.Confidence == "" {
		return fmt.Errorf("%w: confidence is required when available=true", ErrDiagnosisInvalid)
	}
	if _, ok := validDiagnosisConfidence[p.Confidence]; !ok {
		return fmt.Errorf("%w: confidence=%q must be one of high|medium|low",
			ErrDiagnosisInvalid, p.Confidence)
	}
	return nil
}

// MarshalJSON wraps the default marshaller and stamps the canonical
// SchemaVersion when callers leave it unset. This keeps the proto
// constant authoritative without forcing every caller to remember to
// populate the field.
func (p DiagnosisV1) MarshalJSON() ([]byte, error) {
	type alias DiagnosisV1
	if p.SchemaVersion == 0 {
		p.SchemaVersion = DiagnosisV1SchemaVersion
	}
	return json.Marshal(alias(p))
}
