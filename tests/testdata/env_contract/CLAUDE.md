# m27test fixture project

This directory is the target project for `tests/test_stage_env_setu.sh`
(the m27.3 env-contract parity test).

The fixture exists so each stage in `internal/runner/single.go::defaultStageOrder`
spawns a real bash subprocess that sources every `lib/*.sh` and
`stages/*.sh` under `set -euo pipefail`. The parity test scans the
captured subprocess stderr for `unbound variable` trips — a non-zero
count means a contract variable lost its `${VAR:-DEFAULT}` guard in a
recent change.

Agent invocations are short-circuited via `TEKHTON_AGENT_BINARY`
pointed at `testdata/fake_agent.sh` (mode=happy). No real agent work
happens in this fixture.
