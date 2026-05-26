package finalize

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// ExpressPersist is the Go body of _hook_express_persist. The bash
// version called persist_express_config / persist_express_roles from
// lib/express_persist.sh and lib/express.sh.
//
// The express subsystem hasn't been ported to Go yet — m24's scope is
// notes. The hook lives here so the finalize_shim.sh case arm for the
// "notes + express + failure_context" cluster can disappear entirely;
// the bash bodies remain reachable via runBashHookFn until the
// express subsystem ports in its own milestone.
//
// Gates: only on success and only when EXPRESS_MODE_ACTIVE=true.
type ExpressPersist struct{}

// Name implements Hook.
func (h *ExpressPersist) Name() string { return "_hook_express_persist" }

// Run delegates to the bash express functions through a single bash
// invocation, mirroring the original `_hook_express_persist` body.
func (h *ExpressPersist) Run(ctx context.Context, in *Input) error {
	if in.ExitCode != 0 {
		return nil
	}
	if envValue(in, "EXPRESS_MODE_ACTIVE") != "true" {
		return nil
	}
	// persist_express_config lives in lib/express_persist.sh; the
	// chained persist_express_roles lives in lib/express.sh. The bash
	// hook body called persist_express_config unconditionally and
	// persist_express_roles when EXPRESS_PERSIST_ROLES=true. Mirror
	// that in a single bash subprocess so the env stays consistent.
	if in.TekhtonHome == "" {
		return nil
	}
	script := filepath.Join(in.TekhtonHome, "lib", "express_persist.sh")
	if !fileExists(script) {
		return nil
	}
	cmd := exec.CommandContext(ctx, "bash", "-c",
		fmt.Sprintf(`
set -e
. %q
. %q
if [[ "${EXPRESS_PERSIST_CONFIG:-true}" == "true" ]]; then
    persist_express_config "${PROJECT_DIR}"
fi
if [[ "${EXPRESS_PERSIST_ROLES:-false}" == "true" ]]; then
    persist_express_roles "${PROJECT_DIR}"
fi
`,
			script,
			filepath.Join(in.TekhtonHome, "lib", "express.sh"),
		))
	cmd.Dir = in.ProjectDir
	cmd.Stdout = logWriter(in)
	cmd.Stderr = logWriter(in)
	cmd.Env = bashDelegateEnv(in)
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(logWriter(in), "express_persist: %v\n", err)
	}
	return nil
}

// _ keeps the os and exec imports used when fileExists / runBashHookFn
// are not the chosen delegate path.
var _ = os.Stat
