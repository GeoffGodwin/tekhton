# Preflight Parity Test Fixtures (m22)

Each subdirectory contains:
- `fixture/` — the synthetic project layout. The parity test copies this
  into a fresh tmpdir per scenario so the run is hermetic.
- `expected/PREFLIGHT_REPORT.md` — the byte-identical baseline. Captured
  from the bash preflight at m22 close-out, frozen at check-in time.
  After the bash subsystem is deleted (m22 Goal 5), this baseline is the
  only proof the Go orchestrator preserves the bash output format.

The parity gate (`tests/test_preflight_parity.sh`) normalises timestamps
in both the expected baseline and the live Go output before diffing.

## Scenarios

### `green_path/`
Empty-ish fixture: `.claude/pipeline.conf` present, no UI test command,
no docker-compose, no lock files. Bash skips report emission entirely
because no checks are applicable (`total == 0`).

### `env_only_fail/`
Fixture has a `package.json` + `package-lock.json` but no `node_modules`.
Bash records a WARN/FAIL ("node_modules missing") and tries auto-fix
(disabled in the fixture so the result is `fail`).

### `ui_config_autopatch/`
Fixture has a `playwright.config.ts` that uses the interactive HTML
reporter. With `PREFLIGHT_UI_CONFIG_AUTO_FIX=true`, the auto-fix patches
the config to a CI-guarded form and records a `fixed` entry.
