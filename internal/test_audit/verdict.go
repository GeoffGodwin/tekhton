package test_audit

import (
	"context"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"
)

// Verdict is the parsed outcome of an audit report. Three explicit values
// plus the implicit 4th "missing-report → PASS" branch (preserved from the
// bash default).
type Verdict int

const (
	// VerdictPASS — audit passed OR report missing. The 4th implicit outcome
	// (missing report) maps to VerdictPASS to match the bash default.
	VerdictPASS Verdict = iota
	// VerdictCONCERNS — concerns logged; appended to NON_BLOCKING_LOG_FILE.
	VerdictCONCERNS
	// VerdictNEEDS_WORK — rework required; orchestrator triggers re-tester.
	VerdictNEEDS_WORK
)

// String returns the bash-format verdict label.
func (v Verdict) String() string {
	switch v {
	case VerdictCONCERNS:
		return "CONCERNS"
	case VerdictNEEDS_WORK:
		return "NEEDS_WORK"
	default:
		return "PASS"
	}
}

// ErrAuditNeedsWork is the sentinel returned by RouteAuditVerdict on
// NEEDS_WORK. Orchestrator catches it via errors.Is to trigger rework.
var ErrAuditNeedsWork = errors.New("test audit verdict: NEEDS_WORK")

// verdictRE captures the first `Verdict: <token>` line in the audit
// report. Case-insensitive to match the bash `grep -oiE`.
var verdictRE = regexp.MustCompile(`(?i)Verdict:\s*(NEEDS_WORK|PASS|CONCERNS)`)

// ParseAuditVerdict reads the audit report and returns the parsed verdict.
// Missing or unreadable report → VerdictPASS (bash default). Unrecognized
// verdict tokens also return VerdictPASS.
func ParseAuditVerdict(reportPath string) Verdict {
	if reportPath == "" {
		return VerdictPASS
	}
	body, err := os.ReadFile(reportPath)
	if err != nil {
		return VerdictPASS
	}
	m := verdictRE.FindSubmatch(body)
	if len(m) < 2 {
		return VerdictPASS
	}
	switch strings.ToUpper(string(m[1])) {
	case "NEEDS_WORK":
		return VerdictNEEDS_WORK
	case "CONCERNS":
		return VerdictCONCERNS
	default:
		return VerdictPASS
	}
}

// RouteAuditVerdict applies side effects based on verdict:
//   - PASS — log success; return nil.
//   - CONCERNS — append findings to NON_BLOCKING_LOG; return nil.
//   - NEEDS_WORK — return ErrAuditNeedsWork (caller retries).
//   - unknown — treat as PASS (defensive).
func RouteAuditVerdict(ctx context.Context, req *Request, verdict Verdict) error {
	if req == nil {
		return nil
	}
	log := resolveLogger(req)

	switch verdict {
	case VerdictPASS:
		log.Logf("Test audit passed — all tests meet integrity standards.")
		return nil
	case VerdictCONCERNS:
		log.Logf("Test audit raised concerns — logging to %s.",
			fallback(req.NonBlockingFile, ".tekhton/NON_BLOCKING_LOG.md"))
		appendConcernsToNonBlocking(req)
		return nil
	case VerdictNEEDS_WORK:
		log.Logf("Test audit verdict: NEEDS_WORK — routing to tester for rework.")
		return ErrAuditNeedsWork
	default:
		log.Logf("Unknown test audit verdict — treating as PASS.")
		return nil
	}
}

func fallback(s, dflt string) string {
	if s == "" {
		return dflt
	}
	return s
}

// concernRE matches the finding-section headers the bash version greps for.
// The pattern allows any leading whitespace then `####` (markdown H4) then
// the category token.
var concernRE = regexp.MustCompile(
	`(?m)^\s*####\s+(INTEGRITY|SCOPE|COVERAGE|WEAKENING|NAMING)`)

// appendConcernsToNonBlocking copies concern-finding headers from the audit
// report into the non-blocking log. Mirrors the bash branch in
// _route_audit_verdict's CONCERNS arm. Best-effort: failures are logged but
// never block the pipeline.
func appendConcernsToNonBlocking(req *Request) {
	if req.AuditReportFile == "" || req.NonBlockingFile == "" {
		return
	}
	body, err := os.ReadFile(req.AuditReportFile)
	if err != nil {
		return
	}
	matches := concernRE.FindAll(body, -1)
	if len(matches) == 0 {
		return
	}
	f, err := os.OpenFile(req.NonBlockingFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	ts := time.Now().UTC().Format("2006-01-02")
	fmt.Fprintf(f, "\n### Test Audit Concerns (%s)\n", ts)
	for _, m := range matches {
		fmt.Fprintln(f, string(m))
	}
}
