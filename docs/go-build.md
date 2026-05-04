# Go Build & Toolchain (V4)

Tekhton V4 ports the pipeline from Bash to Go via Ship-of-Theseus wedges. The
Go binary is the V4 entry point; today it is a stub that exposes only
`--version` and `--help`. Phase 1+ wedges add subcommands.

## Prerequisites

- **Go 1.23+.** The exact required version is pinned in `go.mod`. Install from
  <https://go.dev/dl/> or your package manager. CI uses
  `actions/setup-go@v5` with `go-version-file: go.mod`, which keeps local and
  CI Go versions in lockstep.
- **make** (any reasonably modern GNU make).
- **golangci-lint** (optional locally — CI runs it on every PR).

To verify your toolchain:

```bash
go version   # must report 1.23 or newer
make help    # lists targets
```

## First-time setup

```bash
# Pull cobra (and any future) deps and refresh go.sum.
make tidy
```

`go mod tidy` is required after editing `go.mod` requires; the committed
`go.sum` is regenerated then.

## Make targets

| Target            | What it does                                                        |
|-------------------|---------------------------------------------------------------------|
| `make build`      | Local-host build → `bin/tekhton`. Default goal.                     |
| `make test`       | `go test ./...`. Acceptable for "no test files" output (Phase 0).   |
| `make vet`        | `go vet ./...`.                                                     |
| `make lint`       | Runs `golangci-lint` if installed; warns and skips otherwise.       |
| `make build-all`  | Cross-compiles all five matrix targets into `bin/`.                 |
| `make tidy`       | `go mod tidy` — refresh `go.sum` after editing requires.            |
| `make clean`      | `rm -rf bin/`.                                                      |

## Cross-compile output layout

`make build-all` produces:

```
bin/tekhton-linux-amd64
bin/tekhton-linux-arm64
bin/tekhton-darwin-amd64
bin/tekhton-darwin-arm64
bin/tekhton-windows-amd64.exe
```

CGO is **disabled** for every target. The single-static-binary promise
depends on it; do not introduce dependencies that require cgo. If a future
wedge needs SQLite, default to `modernc.org/sqlite` (pure Go).

## Version stamping

`bin/tekhton --version` prints the contents of repo-root `VERSION` (trimmed).
The Makefile injects the value via `-ldflags`:

```
-ldflags "-X github.com/geoffgodwin/tekhton/internal/version.Version=$(cat VERSION)"
```

A direct `go build ./cmd/tekhton` (without make) leaves `version.Version` at
the `"dev"` sentinel — useful for spotting unintended raw builds, but not for
release.

> **Why ldflags instead of `//go:embed`?** Go's `embed` package forbids `..`
> in patterns (see `pkg.go.dev/embed`), so the design-doc sketch
> (`//go:embed ../../VERSION` from `internal/version/`) is not valid Go.
> ldflags injection is the idiomatic substitute and avoids duplicating the
> VERSION file inside the package directory.

## CI artifacts

The `Go Build` workflow (`.github/workflows/go-build.yml`) has three jobs:

- **build** — runs `make build-all` and uploads the five binaries as the
  `tekhton-binaries` artifact (14-day retention).
- **vet-test** — runs `make vet` and `make test`.
- **lint** — runs `golangci-lint` via the `golangci/golangci-lint-action@v6`
  action.

Workflow artifacts are reachable from the GitHub Actions run summary page
under the `Artifacts` section.

## Self-host check

`scripts/self-host-check.sh` is the V4 smoke harness. It:

1. Runs `make build`.
2. Prepends `bin/` to `$PATH`.
3. Asserts `tekhton --version` matches `VERSION`.
4. Runs `tekhton.sh --version` to confirm the Bash entry point starts with
   the Go binary on `$PATH`.
5. Optionally runs `tekhton.sh --dry-run` against a fixture task — gated
   behind `TEKHTON_SELF_HOST_DRY_RUN=1` because that invocation calls Claude
   CLI agents and needs auth not present in default CI.

Run it from the repo root:

```bash
bash scripts/self-host-check.sh                       # smoke (no Claude auth)
TEKHTON_SELF_HOST_DRY_RUN=1 bash scripts/self-host-check.sh  # full smoke
```

The script must remain idempotent — running it twice in the same job is
explicitly supported.

## Subcommands

The Go binary currently exposes one production subcommand and the
top-level `--version` / `--help` flags. Subcommand list grows as wedges
land (see DESIGN_v4 Phase 1+).

### `tekhton causal …` (m02)

The causal-event log writer. `lib/causality.sh` is a shim that exec's
this subcommand when the Go binary is on `$PATH`; pipeline callers do
not invoke it directly.

```text
tekhton causal init    --path PATH --cap N --run-id R     # ensure dirs exist
tekhton causal emit    --path PATH --stage S --type T …   # append one event, prints ID
tekhton causal archive --path PATH --run-id R --retention N
tekhton causal status  --path PATH                        # print last event ID
```

The on-disk format is `causal.event.v1` — see
[`internal/proto/causal_v1.go`](../internal/proto/causal_v1.go). Bash
query callers (`lib/causality_query.sh`) read the same JSONL file the Go
writer produces; the file is the seam, the writer is the wedge.

When the Go binary is missing from `$PATH` (fresh clone, test sandbox
with no `make build`), `lib/causality.sh` falls back to an inline bash
writer that produces the same `causal.event.v1` lines. The fallback is
transitional — m04 Phase-1 hardening removes it.

## Troubleshooting

- **`go: command not found` in CI** — `actions/setup-go@v5` has not run yet
  in the failing job. Confirm the job has the `Set up Go` step.
- **`darwin/*` cross-build fails on Linux** — almost always a cgo dep
  pulling in macOS-only headers. Audit recent `go.mod` changes.
- **`bin/tekhton --version` prints `dev`** — the binary was built without
  `make build`. Re-run the make target.
- **`go.sum` checksum mismatch** — run `make tidy` to refresh.
