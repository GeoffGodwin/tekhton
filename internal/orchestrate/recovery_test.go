package orchestrate

import (
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// TestClassify drives the recovery decision tree with every branch reachable
// from lib/orchestrate_classify.sh:121 (`_classify_failure`). The cases here
// are the parity matrix — mirror this list in any future bash counterpart so
// the seam stays diffable.
func TestClassify(t *testing.T) {
	cfg := DefaultConfig()

	cases := []struct {
		name              string
		outcome           StageOutcome
		envGateRetried    bool
		mixedBuildRetried bool
		want              string
	}{
		{
			name:    "upstream sustained outage → save_exit",
			outcome: StageOutcome{ErrorCategory: "UPSTREAM"},
			want:    proto.RecoverySaveExit,
		},
		{
			name: "M130 amend B: max_turns with env/test_infra primary → retry_ui_gate_env",
			outcome: StageOutcome{
				ErrorCategory:    "AGENT_SCOPE",
				ErrorSubcategory: "max_turns",
				PrimaryCat:       "ENVIRONMENT",
				PrimarySub:       "test_infra",
			},
			want: proto.RecoveryRetryUIGateEnv,
		},
		{
			name: "M130 amend B: env-gate already retried this run → fall through to split",
			outcome: StageOutcome{
				ErrorCategory:    "AGENT_SCOPE",
				ErrorSubcategory: "max_turns",
				PrimaryCat:       "ENVIRONMENT",
				PrimarySub:       "test_infra",
			},
			envGateRetried: true,
			want:           proto.RecoverySplit,
		},
		{
			name: "AGENT_SCOPE/max_turns plain → split",
			outcome: StageOutcome{
				ErrorCategory:    "AGENT_SCOPE",
				ErrorSubcategory: "max_turns",
			},
			want: proto.RecoverySplit,
		},
		{
			name: "AGENT_SCOPE/null_run → split",
			outcome: StageOutcome{
				ErrorCategory:    "AGENT_SCOPE",
				ErrorSubcategory: "null_run",
			},
			want: proto.RecoverySplit,
		},
		{
			name: "AGENT_SCOPE/null_activity_timeout → save_exit",
			outcome: StageOutcome{
				ErrorCategory:    "AGENT_SCOPE",
				ErrorSubcategory: "null_activity_timeout",
			},
			want: proto.RecoverySaveExit,
		},
		{
			name: "AGENT_SCOPE/activity_timeout → save_exit",
			outcome: StageOutcome{
				ErrorCategory:    "AGENT_SCOPE",
				ErrorSubcategory: "activity_timeout",
			},
			want: proto.RecoverySaveExit,
		},
		{
			name: "M130 amend A: env/test_infra primary (no error cat) → retry_ui_gate_env",
			outcome: StageOutcome{
				PrimaryCat: "ENVIRONMENT",
				PrimarySub: "test_infra",
			},
			want: proto.RecoveryRetryUIGateEnv,
		},
		{
			name: "M130 amend A: env-gate already retried → save_exit on ENVIRONMENT",
			outcome: StageOutcome{
				ErrorCategory: "ENVIRONMENT",
				PrimaryCat:    "ENVIRONMENT",
				PrimarySub:    "test_infra",
			},
			envGateRetried: true,
			want:           proto.RecoverySaveExit,
		},
		{
			name:    "ENVIRONMENT plain → save_exit",
			outcome: StageOutcome{ErrorCategory: "ENVIRONMENT"},
			want:    proto.RecoverySaveExit,
		},
		{
			name:    "PIPELINE → save_exit",
			outcome: StageOutcome{ErrorCategory: "PIPELINE"},
			want:    proto.RecoverySaveExit,
		},
		{
			name:    "CHANGES_REQUIRED verdict → bump_review",
			outcome: StageOutcome{Verdict: "CHANGES_REQUIRED"},
			want:    proto.RecoveryBumpReview,
		},
		{
			name:    "review_cycle_max verdict → bump_review",
			outcome: StageOutcome{Verdict: "review_cycle_max"},
			want:    proto.RecoveryBumpReview,
		},
		{
			name:    "REPLAN_REQUIRED → save_exit",
			outcome: StageOutcome{Verdict: "REPLAN_REQUIRED"},
			want:    proto.RecoverySaveExit,
		},
		{
			name: "build errors + code_dominant → retry_coder_build",
			outcome: StageOutcome{
				BuildErrorsPresent:  true,
				BuildClassification: "code_dominant",
			},
			want: proto.RecoveryRetryCoderBuild,
		},
		{
			name: "build errors + unknown_only → retry_coder_build",
			outcome: StageOutcome{
				BuildErrorsPresent:  true,
				BuildClassification: "unknown_only",
			},
			want: proto.RecoveryRetryCoderBuild,
		},
		{
			name: "build errors + empty classification → retry_coder_build",
			outcome: StageOutcome{
				BuildErrorsPresent:  true,
				BuildClassification: "",
			},
			want: proto.RecoveryRetryCoderBuild,
		},
		{
			name: "build errors + mixed_uncertain (first try) → retry_coder_build",
			outcome: StageOutcome{
				BuildErrorsPresent:  true,
				BuildClassification: "mixed_uncertain",
			},
			want: proto.RecoveryRetryCoderBuild,
		},
		{
			name: "build errors + mixed_uncertain (already retried) → save_exit",
			outcome: StageOutcome{
				BuildErrorsPresent:  true,
				BuildClassification: "mixed_uncertain",
			},
			mixedBuildRetried: true,
			want:              proto.RecoverySaveExit,
		},
		{
			name: "build errors + noncode_dominant → save_exit",
			outcome: StageOutcome{
				BuildErrorsPresent:  true,
				BuildClassification: "noncode_dominant",
			},
			want: proto.RecoverySaveExit,
		},
		{
			name:    "no error, no verdict, no build errors → save_exit",
			outcome: StageOutcome{},
			want:    proto.RecoverySaveExit,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			l := New(nil, cfg)
			l.envGateRetried = tc.envGateRetried
			l.mixedBuildRetried = tc.mixedBuildRetried
			got := l.Classify(tc.outcome, cfg)
			if got != tc.want {
				t.Fatalf("Classify(%+v) = %q; want %q", tc.outcome, got, tc.want)
			}
		})
	}
}

// TestClassifyKillSwitch asserts that BuildFixClassificationRequired=false
// reverts to pre-M130 behavior (always retry when BUILD_ERRORS_FILE is
// non-empty, regardless of M127 classification).
func TestClassifyKillSwitch(t *testing.T) {
	cfg := DefaultConfig()
	cfg.BuildFixClassificationRequired = false

	cases := []struct {
		classification string
	}{
		{"noncode_dominant"},
		{"mixed_uncertain"},
		{"code_dominant"},
		{""},
	}
	for _, tc := range cases {
		l := New(nil, cfg)
		// Even with mixed-build guard set, the kill-switch wins.
		l.mixedBuildRetried = true
		o := StageOutcome{
			BuildErrorsPresent:  true,
			BuildClassification: tc.classification,
		}
		got := l.Classify(o, cfg)
		if got != proto.RecoveryRetryCoderBuild {
			t.Fatalf("kill-switch with classification=%q: got %q, want retry_coder_build", tc.classification, got)
		}
	}
}

// TestFormatCauseSummary asserts the M129 cause-summary string matches the
// shape lib/orchestrate_state.sh:79 builds.
func TestFormatCauseSummary(t *testing.T) {
	cases := []struct {
		name string
		o    StageOutcome
		want string
	}{
		{
			name: "primary only",
			o:    StageOutcome{PrimaryCat: "ENVIRONMENT", PrimarySub: "test_infra"},
			want: "ENVIRONMENT/test_infra",
		},
		{
			name: "primary with signal",
			o: StageOutcome{
				PrimaryCat:    "ENVIRONMENT",
				PrimarySub:    "test_infra",
				PrimarySignal: "playwright html serving stuck",
			},
			want: "ENVIRONMENT/test_infra (playwright html serving stuck)",
		},
		{
			name: "primary + secondary",
			o: StageOutcome{
				PrimaryCat:   "ENVIRONMENT",
				PrimarySub:   "test_infra",
				SecondaryCat: "AGENT_SCOPE",
				SecondarySub: "max_turns",
			},
			want: "ENVIRONMENT/test_infra; secondary: AGENT_SCOPE/max_turns",
		},
		{
			name: "secondary only",
			o:    StageOutcome{SecondaryCat: "PIPELINE", SecondarySub: "internal"},
			want: "PIPELINE/internal",
		},
		{
			name: "neither",
			o:    StageOutcome{},
			want: "",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := formatCauseSummary(tc.o)
			if got != tc.want {
				t.Fatalf("formatCauseSummary = %q; want %q", got, tc.want)
			}
		})
	}
}
