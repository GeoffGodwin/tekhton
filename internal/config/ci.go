package config

import (
	"fmt"
	"os"
)

// CIPlatform represents a recognised CI/CD provider.
type CIPlatform string

const (
	CINone        CIPlatform = ""
	CIGitHub      CIPlatform = "GitHub Actions"
	CIGitLab      CIPlatform = "GitLab CI"
	CICircle      CIPlatform = "CircleCI"
	CITravis      CIPlatform = "Travis CI"
	CIBuildkite   CIPlatform = "Buildkite"
	CIJenkins     CIPlatform = "Jenkins"
	CIAzure       CIPlatform = "Azure DevOps"
	CITeamCity    CIPlatform = "TeamCity"
	CIBitbucket   CIPlatform = "Bitbucket Pipelines"
	CIGenericTrue CIPlatform = "CI (generic)"
)

// DetectCI inspects the environment and returns the detected platform, or
// CINone when no CI signal is present. Pure-bash port of
// _detect_runtime_ci_environment + _get_ci_platform_name from
// lib/config_defaults_ci.sh — the named-platform branches run in priority
// order so the diagnostic line shows the real platform when both
// `CI=true` and a named flag are set.
func DetectCI() CIPlatform {
	if os.Getenv("GITHUB_ACTIONS") == "true" {
		return CIGitHub
	}
	if os.Getenv("GITLAB_CI") == "true" {
		return CIGitLab
	}
	if os.Getenv("CIRCLECI") == "true" {
		return CICircle
	}
	if os.Getenv("TRAVIS") == "true" {
		return CITravis
	}
	if os.Getenv("BUILDKITE") == "true" {
		return CIBuildkite
	}
	if os.Getenv("JENKINS_URL") != "" {
		return CIJenkins
	}
	if os.Getenv("TF_BUILD") != "" {
		return CIAzure
	}
	if os.Getenv("TEAMCITY_VERSION") != "" {
		return CITeamCity
	}
	if os.Getenv("BITBUCKET_BUILD_NUMBER") != "" {
		return CIBitbucket
	}
	if os.Getenv("CI") == "true" {
		return CIGenericTrue
	}
	return CINone
}

// applyCIGateDefault encodes the m138 contract:
//
//   - If TEKHTON_UI_GATE_FORCE_NONINTERACTIVE was set in pipeline.conf, the
//     explicit value wins (Values already carries it; nothing to do).
//   - Else if a CI signal is detected, set TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1
//     and TEKHTON_CI_ENVIRONMENT_DETECTED=1.
//   - Else set TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0 (only as a default —
//     the late-defaults pass also covers this) and TEKHTON_CI_ENVIRONMENT_DETECTED=0.
//
// Mirrors _apply_ci_ui_gate_defaults. The diagnostic stderr line is emitted
// when VERBOSE_OUTPUT=true and auto-elevation fired; suppressed when the
// caller passes opts.SuppressDiagnostics (used by tests).
func applyCIGateDefault(cfg *Config, opts LoadOptions) {
	platform := DetectCI()
	cfg.CIPlatform = string(platform)
	cfg.CIDetected = platform != CINone

	if cfg.KeysSet["TEKHTON_UI_GATE_FORCE_NONINTERACTIVE"] {
		// Operator override wins — diagnostic is suppressed (matches bash).
		// The CI-detected env var still records the platform for downstream
		// consumers (gates_ui_helpers.sh's GAP-2 diagnostic).
		if cfg.CIDetected {
			cfg.Values["TEKHTON_CI_ENVIRONMENT_DETECTED"] = "1"
		} else {
			cfg.Values["TEKHTON_CI_ENVIRONMENT_DETECTED"] = "0"
		}
		return
	}

	if cfg.CIDetected {
		cfg.Values["TEKHTON_UI_GATE_FORCE_NONINTERACTIVE"] = "1"
		cfg.Values["TEKHTON_CI_ENVIRONMENT_DETECTED"] = "1"
		// Mirror the bash diagnostic so existing operator-facing UX is
		// preserved. Kept on stderr so stdout (the `--emit shell` payload)
		// stays clean and sourceable.
		if !opts.SuppressDiagnostics && cfg.Values["VERBOSE_OUTPUT"] == "true" {
			fmt.Fprintf(os.Stderr,
				"[tekhton] CI environment detected (%s) — TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 (auto)\n",
				platform)
		}
		return
	}

	// Not in CI, not user-set — base default kicks in via late defaults.
	cfg.Values["TEKHTON_UI_GATE_FORCE_NONINTERACTIVE"] = "0"
	cfg.Values["TEKHTON_CI_ENVIRONMENT_DETECTED"] = "0"
}
