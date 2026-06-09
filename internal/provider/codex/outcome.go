// Package codex — Outcome derivation from decoded event stream.
// V5 m08 — deriveOutcome maps events + exit code to provider.Outcome.
package codex

import "github.com/geoffgodwin/tekhton/internal/provider"

// OutcomeResult holds the derived outcome fields from a Codex run.
type OutcomeResult struct {
	Outcome          provider.Outcome
	TurnsUsed        int
	ErrorCategory    string
	ErrorSubcategory string
	ErrorMessage     string
	NullRun          bool
	LastReportPath   string
}

// deriveOutcome walks events and produces a typed result.
//
// Mapping table:
//   - If any error event with UsageLimitExceeded → OutcomeUpstreamError, UPSTREAM/QUOTA
//   - If any error event with ContextWindowExceeded → OutcomeUpstreamError, UPSTREAM/CONTEXT
//   - If any error event with Unauthorized → OutcomeUpstreamError, UPSTREAM/AUTH
//   - If any task_complete event → OutcomeSuccess (unless overridden by error)
//   - TurnsUsed = count of task_complete events
//   - NullRun = no task_complete events and exit 0
//   - Fallback: exit code mapping via interpretExitCode
func deriveOutcome(events []Event, exitCode int) (*OutcomeResult, error) {
	res := &OutcomeResult{}

	var taskCompleteCount int
	var errorOutcome *OutcomeResult

	for _, ev := range events {
		switch ev.Msg.Kind {
		case EventTaskComplete:
			taskCompleteCount++
		case EventError:
			if ev.Msg.Error != nil {
				o := mapErrorToOutcome(ev.Msg.Error)
				if errorOutcome == nil {
					errorOutcome = o
				}
			}
		}
	}

	res.TurnsUsed = taskCompleteCount

	if errorOutcome != nil {
		res.Outcome = errorOutcome.Outcome
		res.ErrorCategory = errorOutcome.ErrorCategory
		res.ErrorSubcategory = errorOutcome.ErrorSubcategory
		res.ErrorMessage = errorOutcome.ErrorMessage
		return res, nil
	}

	if taskCompleteCount > 0 && exitCode == 0 {
		res.Outcome = provider.OutcomeSuccess
		return res, nil
	}

	if taskCompleteCount == 0 && exitCode == 0 {
		res.Outcome = provider.OutcomeSuccess
		res.NullRun = true
		return res, nil
	}

	res.Outcome = interpretExitCode(exitCode)
	return res, nil
}

func mapErrorToOutcome(e *ErrorEvent) *OutcomeResult {
	res := &OutcomeResult{
		Outcome:       provider.OutcomeUpstreamError,
		ErrorCategory: "UPSTREAM",
		ErrorMessage:  e.Message,
	}
	if e.CodexErrorInfo == nil {
		res.ErrorSubcategory = "UNKNOWN"
		return res
	}
	switch e.CodexErrorInfo.Kind {
	case ErrorKindUsageLimitExceeded:
		res.ErrorSubcategory = "QUOTA"
	case ErrorKindContextWindowExceeded:
		res.ErrorSubcategory = "CONTEXT"
	case ErrorKindUnauthorized:
		res.ErrorSubcategory = "AUTH"
	case ErrorKindServerOverloaded:
		res.ErrorSubcategory = "OVERLOAD"
	case ErrorKindInternalServerError:
		res.ErrorSubcategory = "SERVER_ERROR"
	default:
		res.ErrorSubcategory = "OTHER"
	}
	return res
}
