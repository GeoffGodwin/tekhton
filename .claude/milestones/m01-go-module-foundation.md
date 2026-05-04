<!-- milestone-meta
id: "01"
status: "done"
-->

# m01 — Go Module Foundation

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | V4 ports Tekhton from bash to Go via Ship-of-Theseus wedges. Before the first wedge can land, the Go module, build, CI, and self-host harness must exist and be wired through the same repo without disturbing any bash code path. |
| **Gap** | The repo contains zero Go code, no `go.mod`, no Go CI matrix, and no harness that runs Tekhton-on-Tekhton with a Go binary present in the toolchain. Phase 1 wedges (m02 causal log, m03 state) cannot start until this foundation exists. |
| **m01 fills** | Bootstrap the Go module in-repo, stand up Cobra root + `--version`, cross-compile to five OS/arch targets in CI, and add `scripts/self-host-check.sh` that re-runs the V3 self-host smoke test with the Go binary on `$PATH` (initially as a no-op). End state: the binary exists, ships in CI artifacts, and is invoked by no production code path. |
| **Depends on** | — (greenfield) |
| **Files changed** | `go.mod`, `go.sum`, `cmd/tekhton/main.go`, `internal/version/version.go`, `Makefile`, `.github/workflows/go-build.yml`, `scripts/self-host-check.sh`, `docs/go-build.md`, `.gitignore` |
| **Stability after this milestone** | Stable. Pure addition; no bash file is modified. Tekhton's existing pipeline behavior is byte-identical before and after. |
| **Dogfooding stance** | Safe to land in working copy immediately. The Go binary is on `$PATH` but called by no bash code, so a regression here can only manifest as a CI build break — not a runtime failure during a self-hosted pipeline run. |

---

## Design

### Goal 1 — Module bootstrap

`go.mod` at repo root, module path `github.com/geoffgodwin/tekhton`. Pin to the latest stable Go (`go 1.23` at time of writing). `go.sum` checked in. The module sits alongside `tekhton.sh`, `lib/`, and `tools/` — no separate fork, no submodule.

### Goal 2 — Cobra root command

`cmd/tekhton/main.go` defines a Cobra root command with no subcommands yet. `--version` reads the existing repo-root `VERSION` file via `internal/version/version.go` (`//go:embed VERSION`) and prints it. `--help` produces standard Cobra output. Any other invocation prints help and exits non-zero.

```go
// internal/version/version.go
package version

import _ "embed"

//go:embed ../../VERSION
var Version string
```

The version string is trimmed of trailing whitespace at print time. Subcommand wiring is the responsibility of m02+ as wedges arrive.

### Goal 3 — Cross-platform build

`Makefile` exposes:

| Target | Behavior |
|--------|----------|
| `make build` | Local-host build: `go build -trimpath -ldflags="-s -w" -o bin/tekhton ./cmd/tekhton` |
| `make test` | `go test ./...` |
| `make build-all` | Cross-compiles to `linux/amd64`, `linux/arm64`, `darwin/amd64`, `darwin/arm64`, `windows/amd64`. Output: `bin/tekhton-<os>-<arch>[.exe]`. CGO disabled. |
| `make clean` | `rm -rf bin/` |

CGO is off everywhere by default per Risk §8 — the single-static-binary promise depends on it.

### Goal 4 — CI matrix

`.github/workflows/go-build.yml`:

- Triggers on PR + push to `main` and `feature/GoWedges`.
- One job runs `make build-all` on `ubuntu-latest`. Five binaries uploaded as workflow artifacts.
- A separate job runs `go vet ./...` and `go test ./...` (no coverage gate yet — that lands in m04).
- A third job runs `golangci-lint` with the "advanced" preset (Risk §9) against `./...`.

The CI does NOT run `bash tests/run_tests.sh` here — the bash test suite stays gated by its existing CI rules. Phase 0 only adds Go CI.

### Goal 5 — Self-host check

`scripts/self-host-check.sh` reproduces the V3 self-host smoke run: clone-fresh, run `tekhton.sh --dry-run` against a fixture task, assert the exit code and presence of expected artifacts. m01 adds two changes vs the existing harness:

1. Builds the Go binary first via `make build` and prepends `bin/` to `$PATH` for the run.
2. Asserts `tekhton --version` matches the contents of `VERSION` (proves the Go binary is reachable).

The bash pipeline runs the exact same way it did before — the Go binary's presence on `$PATH` is observed but unused.

### Goal 6 — Documentation

`docs/go-build.md` (new, ~80 lines): how to install Go locally, how to build, how to cross-compile, how the binary is wired into `$PATH` during pipeline runs, where to find CI artifacts. One-page max — this is dev-onboarding, not a manual.

`.gitignore`: add `bin/` and `*.test` (Go convention).

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `go.mod`, `go.sum` | Create | Module bootstrap, no third-party deps yet beyond `cobra`. |
| `cmd/tekhton/main.go` | Create | Cobra root + `--version`. ~40 lines. |
| `internal/version/version.go` | Create | `//go:embed VERSION` and exported `Version` string. |
| `Makefile` | Create | `build`, `test`, `build-all`, `clean` targets. |
| `.github/workflows/go-build.yml` | Create | CI matrix: build, vet, lint. |
| `scripts/self-host-check.sh` | Create | V3 self-host smoke run with Go binary on `$PATH`. |
| `docs/go-build.md` | Create | One-page Go build/install doc. |
| `.gitignore` | Modify | Add `bin/` and `*.test`. |

---

## Acceptance Criteria

- [ ] `make build` on a clean checkout produces `bin/tekhton`; `bin/tekhton --version` prints the contents of repo-root `VERSION` (trimmed).
- [ ] `make build-all` produces all five expected binaries; each runs `--version` correctly on its target platform (verified in CI by spinning up the matching runner where available, otherwise by `file bin/tekhton-*` shape check).
- [ ] `make test` exits 0 with no test files yet (Go's "no tests" output is acceptable).
- [ ] `go vet ./...` clean; `golangci-lint run ./...` clean.
- [ ] CI workflow `go-build.yml` passes on the V4 branch with all three jobs (build, vet+test, lint) green.
- [ ] `scripts/self-host-check.sh` exits 0: builds the Go binary, runs `tekhton.sh --dry-run` on a fixture task with `bin/` on `$PATH`, asserts `tekhton --version` output matches `VERSION`.
- [ ] No file under `lib/`, `stages/`, `prompts/`, or `tools/` is modified by this milestone.
- [ ] `bash tests/run_tests.sh` produces identical output before and after this milestone (parity check, archived to artifact).
- [ ] `docs/go-build.md` exists and covers: prerequisite install, `make` targets, cross-compile output layout, CI artifact location.
- [ ] `.gitignore` excludes `bin/` and `*.test`; no `bin/` artifact appears in `git status` after `make build-all`.

## Watch For

- **CGO must stay disabled.** Any dep that pulls in cgo (e.g. `mattn/go-sqlite3`) breaks the static-binary promise (Risk §8). If a future m needs SQLite, default to `modernc.org/sqlite` (pure Go).
- **Go version pinning.** Pin `go 1.23` (or current stable at land time) in `go.mod`. Drift between local and CI Go versions is a real source of flake — set `actions/setup-go` to read `go-version-file: go.mod`.
- **`//go:embed` path is relative to the source file.** The `..` traversal in `internal/version/version.go` is correct only because the repo layout is fixed. If `cmd/tekhton/` ever moves, the embed path changes.
- **Five-target build from one host.** `darwin/*` targets cross-compile cleanly only with CGO off. Verify locally on Linux before relying on CI.
- **Self-host check must remain idempotent.** It's safe to run twice in the same CI job. Don't introduce lockfile or state-file writes that fail on re-run.
- **Don't add subcommands here.** m01 ships a stub root only. `tekhton causal …`, `tekhton supervise …`, etc. are wired by their respective wedges.

## Seeds Forward

- **m02 causal log:** `internal/causal/` is the first concrete package; its package layout (one `Log` value, append channel, eviction mutex) is foreshadowed by `cmd/tekhton/`'s shape.
- **m04 hardening:** the 80% coverage gate lands then. m01 deliberately ships zero Go code paths so the coverage gate has nothing to fail on yet.
- **m05+ supervisor:** the `tekhton supervise` subcommand will be the first call site that bash code actually invokes. m01 only proves the binary builds and ships; the runtime callability is exercised first by m02's `tekhton causal emit`.
- **Versioning convention:** `tekhton --version` becomes the single source of truth across bash and Go. The VERSION file format (`MAJOR.MINOR.PATCH` per CLAUDE.md) is preserved so finalize-stage version bumping continues to work unchanged.
