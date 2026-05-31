// migration.go — Go port of lib/diagnose_rules_migration.sh.

package rules

import (
	"fmt"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/diagnose"
	terr "github.com/geoffgodwin/tekhton/internal/errors"
)

// MigrationCrash — port of _rule_migration_crash.
//
// Two emit paths:
//   - LAST_FAILURE_CONTEXT.json classification == "MIGRATION_FAILURE" → high.
//   - MIGRATION_BACKUP_DIR/pre-* exists AND pipeline.conf is missing or
//     missing the TEKHTON_CONFIG_VERSION= line → medium.
type MigrationCrash struct{}

func (MigrationCrash) Name() string { return "_rule_migration_crash" }

func (MigrationCrash) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	failureCtx := ".claude/LAST_FAILURE_CONTEXT.json"
	if projectFileExists(c, failureCtx) {
		body := readProjectFile(c, failureCtx)
		class := terr.ExtractFailureCtxClassification(body)
		if class == "MIGRATION_FAILURE" {
			fromVer := terr.ExtractFailureCtxMigrationFrom(body)
			if fromVer == "" {
				fromVer = "?"
			}
			toVer := terr.ExtractFailureCtxMigrationTo(body)
			if toVer == "" {
				toVer = "?"
			}
			return diagnose.Diagnosis{
				Classification: "MIGRATION_FAILURE",
				Confidence:     diagnose.ConfidenceHigh,
				Stage:          c.Stage,
				Suggestions: []string{
					fmt.Sprintf("Migration from V%s to V%s failed.", fromVer, toVer),
					"This usually happens when running express mode (no pipeline.conf) against an older Tekhton version.",
					"Options:",
					"  1. Rollback the failed migration: tekhton --migrate --rollback",
					"  2. Initialize the project properly: tekhton --init",
					"  3. If already rolled back, re-run your task — the fix should prevent recurrence",
				},
			}, true
		}
	}

	// Source 2: backup dir + missing/un-versioned pipeline.conf.
	if len(c.MigrationBackups) == 0 {
		return diagnose.Diagnosis{}, false
	}
	confRel := ".claude/pipeline.conf"
	confPath := filepath.Join(projectOrDot(c.ProjectDir), confRel)
	if projectFileExists(c, confRel) {
		body := readProjectFile(c, confRel)
		if terr.MatchPipelineConfigVersionPin(body) {
			return diagnose.Diagnosis{}, false
		}
		_ = confPath // path captured for diagnostics; rule does not reference it in output
	}
	return diagnose.Diagnosis{
		Classification: "MIGRATION_FAILURE",
		Confidence:     diagnose.ConfidenceMedium,
		Stage:          c.Stage,
		Suggestions: []string{
			"A migration backup exists but the migration did not complete.",
			"Options:",
			"  1. Rollback: tekhton --migrate --rollback",
			"  2. Retry migration: tekhton --migrate",
			"  3. Initialize fresh: tekhton --init",
		},
	}, true
}

// VersionMismatch — port of _rule_version_mismatch.
//
// The bash rule's guard chain relies on:
//   - `detect_config_version` bash function — Go reads
//     `TEKHTON_CONFIG_VERSION=` directly from pipeline.conf.
//   - `_version_lt` bash function — Go uses lexicographic semver comparison.
//
// The rule fires when pipeline.conf pins a version older than the
// MAJOR.MINOR of TEKHTON_VERSION.
type VersionMismatch struct{}

func (VersionMismatch) Name() string { return "_rule_version_mismatch" }

func (VersionMismatch) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	confRel := ".claude/pipeline.conf"
	if !projectFileExists(c, confRel) {
		return diagnose.Diagnosis{}, false
	}
	body := readProjectFile(c, confRel)
	configVer := extractPipelineConfigVersion(body)
	if configVer == "" {
		return diagnose.Diagnosis{}, false
	}
	runningRaw := envOr("TEKHTON_VERSION", "")
	runningMajor := majorMinor(runningRaw)
	if runningMajor == "" {
		runningMajor = "0.0"
	}
	if !versionLT(configVer, runningMajor) {
		return diagnose.Diagnosis{}, false
	}
	return diagnose.Diagnosis{
		Classification: "VERSION_MISMATCH",
		Confidence:     diagnose.ConfidenceMedium,
		Stage:          c.Stage,
		Suggestions: []string{
			fmt.Sprintf("Project config is V%s but Tekhton is V%s.", configVer, runningMajor),
			"This may cause features to not work as expected.",
			"Run: tekhton --migrate",
		},
	}, true
}

// projectOrDot mirrors lib/diagnose_helpers.sh's `${PROJECT_DIR:-.}` default.
func projectOrDot(p string) string {
	if p == "" {
		return "."
	}
	return p
}
