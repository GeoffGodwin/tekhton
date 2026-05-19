# Tekhton V4 Go Makefile
# -----------------------
# m01 lays the foundation. Subsequent wedges (m02+) add subcommands but should
# not need to touch this file beyond adding new test packages.

# Read VERSION at make-invocation time. tr strips the trailing newline that
# `cat` preserves so the version flag value is exactly the file's payload.
VERSION_STRING := $(shell tr -d '[:space:]' < VERSION)

MODULE        := github.com/geoffgodwin/tekhton
LDFLAGS       := -s -w -X $(MODULE)/internal/version.Version=$(VERSION_STRING)
BUILD_FLAGS   := -trimpath -ldflags='$(LDFLAGS)'
PKG_MAIN      := ./cmd/tekhton
BIN_DIR       := bin
BIN_NAME      := tekhton

# Cross-compile matrix. Format: os/arch[/exe-suffix].
# darwin and linux on amd64+arm64 cover the common dev + CI runners; windows
# amd64 covers the WSL → native fallback path. CGO is disabled everywhere
# (m01 Risk §8 — single-static-binary promise).
CROSS_TARGETS := \
	linux/amd64 \
	linux/arm64 \
	darwin/amd64 \
	darwin/arm64 \
	windows/amd64

# Allow callers to override the go binary (useful when go isn't on PATH for
# the invoking shell — e.g., ~/.local/go/bin in some user setups). Falls
# through to plain `go`, which resolves via PATH as usual.
GO ?= go

GOFLAGS_CROSS := CGO_ENABLED=0

.DEFAULT_GOAL := build

.PHONY: build test build-all clean tidy vet lint help dogfood self-host

build: ## Build local-host binary into bin/tekhton.
	@mkdir -p $(BIN_DIR)
	$(GO) build $(BUILD_FLAGS) -o $(BIN_DIR)/$(BIN_NAME) $(PKG_MAIN)

test: ## Run go test across all packages. Acceptable for "no test files" output.
	$(GO) test ./...

vet: ## Run go vet across all packages.
	$(GO) vet ./...

lint: ## Run golangci-lint if installed; otherwise warn and continue.
	@if command -v golangci-lint >/dev/null 2>&1; then \
		golangci-lint run ./...; \
	else \
		echo "golangci-lint not installed — skipping. CI installs it explicitly."; \
	fi

tidy: ## Refresh go.sum hashes (run after editing go.mod requires).
	$(GO) mod tidy

build-all: ## Cross-compile to all CROSS_TARGETS.
	@mkdir -p $(BIN_DIR)
	@for target in $(CROSS_TARGETS); do \
		os=$$(echo $$target | cut -d/ -f1); \
		arch=$$(echo $$target | cut -d/ -f2); \
		out="$(BIN_DIR)/$(BIN_NAME)-$$os-$$arch"; \
		if [ "$$os" = "windows" ]; then out="$$out.exe"; fi; \
		echo "==> $$os/$$arch -> $$out"; \
		$(GOFLAGS_CROSS) GOOS=$$os GOARCH=$$arch $(GO) build $(BUILD_FLAGS) -o "$$out" $(PKG_MAIN) || exit 1; \
	done

clean: ## Remove build artifacts.
	rm -rf $(BIN_DIR)

help: ## List targets.
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# m20 — Dogfooding cutover.
# `make self-host` is the 15-scenario parity matrix. `make dogfood` is the
# canonical "is the cutover live and working" command — runs the matrix and
# verifies the version is in lockstep with VERSION.
self-host: build ## Run the 15-scenario self-host parity matrix.
	@bash scripts/self-host-check.sh

dogfood: self-host ## Run the cutover gate: parity matrix + version lockstep.
	@printf '\n[dogfood] cutover gate: tekhton.sh dispatcher routes run-flags to tekhton run.\n'
	@printf '[dogfood] post-m20 milestones run via tekhton run --milestone <id>.\n'
