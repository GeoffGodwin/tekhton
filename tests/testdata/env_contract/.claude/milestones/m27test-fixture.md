<!-- milestone-meta
id: "m27test"
status: "pending"
-->

# m27test — Env Contract Parity Fixture

## Overview

This is a fixture milestone consumed by `tests/test_stage_env_setu.sh`.
It exists to give the m27.3 parity test a milestone id to pass to
`tekhton run-stage` so each stage's bash subprocess sources every
`lib/*.sh` and `stages/*.sh` under `set -euo pipefail`.

The fixture deliberately references no real files — the parity test
short-circuits agent invocations via `TEKHTON_AGENT_BINARY` pointed at
`testdata/fake_agent.sh`. No stage body is expected to complete its
work; the surface under test is the subprocess startup path.

## Design

The single goal is "the bash subprocesses survive `set -u`". Any
content beyond that is decoration.

## Acceptance Criteria

- [ ] Fixture loads without error under `tekhton config validate`.
- [ ] `tests/test_stage_env_setu.sh` exits 0 when nothing has regressed.
