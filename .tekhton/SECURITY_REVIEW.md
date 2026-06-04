## Summary
This change adds the m42 no-op TEST_CMD detection feature across three layers: a new Go preflight check (`internal/preflight/test_cmd.go`), a new bash helper (`lib/hooks_final_checks_helpers.sh`), and guards in `lib/hooks_final_checks.sh` and `lib/milestone_acceptance.sh` that short-circuit when TEST_CMD is a recognized no-op. Supporting changes include an ecosystem manifest prober for init config (`lib/init_config_test_cmd.sh`), a `TestsRun` field on `internal/proto/run_v1.go`, and an updated preflight orchestrator. All changed code operates exclusively on operator-configured values and local filesystem paths, with no external network input, no credentials, and no authentication surfaces. The security posture is sound.

## Findings
None

## Verdict
CLEAN
