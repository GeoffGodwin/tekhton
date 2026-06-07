package review

import (
	"context"
	"fmt"
	"os"

	"github.com/geoffgodwin/tekhton/internal/proto"
	reviewparse "github.com/geoffgodwin/tekhton/internal/review"
	"github.com/geoffgodwin/tekhton/internal/stages/staglog"
)

// SpecialistRunner is the seam to the bash run_specialist_reviews subsystem
// (lib/specialists.sh). The default implementation is a noop returning empty
// blockers — production wedges may override via SetSpecialistRunner to drive
// the bash flow, and tests substitute fakes to exercise the three branches
// of the post-loop specialist gate.
//
// Returns the SPECIALIST_BLOCKERS string the bash function exports — empty or
// "None" means no blockers, anything else feeds into RouteSpecialistRework.
type SpecialistRunner interface {
	Run(ctx context.Context, projectDir string) (string, error)
}

// defaultSpecialist is the package-level seam — defaults to the no-blockers
// outcome so a Go-only review run completes naturally. The bash specialist
// machinery is reachable via a future shim if a production deployment
// re-engages it post-port.
var specialistRunner SpecialistRunner = noSpecialist{}

// SetSpecialistRunner replaces the package-level specialist seam.
func SetSpecialistRunner(r SpecialistRunner) SpecialistRunner {
	prev := specialistRunner
	specialistRunner = r
	return prev
}

// finalizeApproved is the post-cycle-loop branch. The cycle loop returned
// cycleAccept; this function decides whether the specialist post-loop branch
// engages and what verdict the stage ultimately emits.
func finalizeApproved(ctx context.Context, req *proto.StageRequestV1, cfg *config,
	report *reviewparse.Report, budget *reviewparse.CycleBudget,
	agentCalls int, log staglog.Logger,
) (*proto.StageResultV1, error) {
	if specialistRunner == nil {
		return approvedResult(req, report, budget, agentCalls), nil
	}
	specialistBlockers, err := specialistRunner.Run(ctx, cfg.ProjectDir)
	if err != nil {
		log.Warn(fmt.Sprintf("Specialist runner error: %v", err))
		return approvedResult(req, report, budget, agentCalls), nil
	}

	decision := reviewparse.RouteSpecialistRework(specialistBlockers, *budget)
	switch decision {
	case reviewparse.SpecialistPassthrough:
		return approvedResult(req, report, budget, agentCalls), nil

	case reviewparse.SpecialistExhausted:
		// Bash review_helpers.sh:21-27 — write state and exit. We surface as
		// verdict=fail / specialist_blockers.
		meta := map[string]string{
			"verdict":                "CHANGES_REQUIRED",
			"specialist_report_file": cfg.SpecialistReportFile,
		}
		return &proto.StageResultV1{
			Proto:      proto.StageResultProtoV1,
			Stage:      req.Stage,
			Verdict:    proto.VerdictFail,
			ExitReason: "specialist_blockers",
			AgentCalls: agentCalls,
			Error:      metaToError(meta),
		}, nil

	case reviewparse.SpecialistRework:
		// Append the specialist section to REVIEWER_REPORT.md (byte-parity
		// with bash review_helpers.sh:12-16).
		section := reviewparse.FormatSpecialistSection(specialistBlockers)
		if err := appendToFile(cfg.ReviewerReportFile, section); err != nil {
			log.Warn(fmt.Sprintf("Append specialist section: %v", err))
		}

		// Bump cycle counter — bash review_helpers.sh:58 increments REVIEW_CYCLE
		// before the post-specialist reviewer pass even if it would exceed Max.
		// The subsequent runOneCycle's IsExhausted() check is the only gate.
		budget.Increment()

		// Senior coder rework + build gate + escalation.
		if err := invokeCoderRework(ctx, cfg, *budget); err != nil {
			log.Warn(fmt.Sprintf("Specialist senior coder rework: %v", err))
		}
		agentCalls++

		if err := buildGateRunner.Run(ctx, cfg.ProjectDir, "post-specialist-rework"); err != nil {
			log.Warn("Build gate failed after specialist rework — escalating.")
			if err := invokeBuildFixMinimal(ctx, cfg); err != nil {
				log.Warn(fmt.Sprintf("Specialist build_fix_minimal: %v", err))
			}
			agentCalls++
			if err := buildGateRunner.Run(ctx, cfg.ProjectDir, "post-specialist-retry"); err != nil {
				log.Warn("Specialist rework left the build broken.")
				return failResult(req, "specialist_build_failure", agentCalls, map[string]string{
					"specialist_report_file": cfg.SpecialistReportFile,
				}), nil
			}
		}

		// Re-run reviewer pass — bash review_helpers.sh:61-77.
		cycleOut, err := runOneCycle(ctx, cfg, budget, 0, log)
		if err != nil {
			return nil, err
		}
		agentCalls += cycleOut.AgentCalls
		if cycleOut.Report != nil && cycleOut.Report.IsApproved() {
			return approvedResult(req, cycleOut.Report, budget, agentCalls), nil
		}
		return blockersRemainResult(req, cycleOut.Report, budget, agentCalls), nil
	}
	return nil, fmt.Errorf("review: unreachable specialist decision %v", decision)
}

// appendToFile opens a file in append mode and writes the supplied content.
// Used by the specialist-rework branch to splice the FormatSpecialistSection
// block onto REVIEWER_REPORT.md.
func appendToFile(path, content string) error {
	if path == "" {
		return nil
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(content)
	return err
}

// noSpecialist is the default SpecialistRunner — returns no blockers.
type noSpecialist struct{}

func (noSpecialist) Run(_ context.Context, _ string) (string, error) { return "", nil }
