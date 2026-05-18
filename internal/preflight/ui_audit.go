package preflight

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// UIConfigCheck ports lib/preflight_checks_ui.sh — the M131 UI test
// framework config audit. Detects test framework config patterns that
// would cause Tekhton's gated subprocess execution to hang on an
// interactive serve-and-wait loop or never-terminating watch mode.
//
// The four PREFLIGHT_UI_* env vars exported below are public contract
// consumed by the UI gate normaliser, RUN_SUMMARY enrichment, diagnose
// rules, and integration tests. Renaming or changing value semantics
// breaks downstream consumers silently — see Watch For in m131.
type UIConfigCheck struct{}

// Name returns the canonical check name.
func (UIConfigCheck) Name() string { return "ui_audit" }

// Run dispatches to per-framework scanners (Playwright, Cypress, Jest /
// Vitest). The dispatcher is gated on UI_TEST_CMD being configured and
// PREFLIGHT_UI_CONFIG_AUDIT_ENABLED being true (default true).
func (UIConfigCheck) Run(_ context.Context, in *Input) Result {
	resetUIEnvExports()

	if !uiAuditEnabled(in) {
		return Result{}
	}
	uiCmd := in.Getenv("UI_TEST_CMD")
	if uiCmd == "" || uiCmd == "true" {
		return Result{}
	}

	var r Result
	r.Findings = append(r.Findings, scanPlaywright(in)...)
	r.Findings = append(r.Findings, scanCypress(in)...)
	r.Findings = append(r.Findings, scanJestVitest(in)...)
	return r
}

func uiAuditEnabled(in *Input) bool {
	v := strings.ToLower(in.GetenvDefault("PREFLIGHT_UI_CONFIG_AUDIT_ENABLED", "true"))
	return v == "true" || v == "1" || v == "yes"
}

// resetUIEnvExports clears the four PREFLIGHT_UI_* contract vars before
// each run so a re-invocation in the same process starts clean. Mirrors
// the bash `unset` at the top of `_preflight_check_ui_test_config`.
func resetUIEnvExports() {
	_ = os.Unsetenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED")
	_ = os.Unsetenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE")
	_ = os.Unsetenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE")
	_ = os.Unsetenv("PREFLIGHT_UI_REPORTER_PATCHED")
}

func setUIEnvExports(rule, file string, patched bool) {
	_ = os.Setenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED", "1")
	_ = os.Setenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE", rule)
	_ = os.Setenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE", file)
	if patched {
		_ = os.Setenv("PREFLIGHT_UI_REPORTER_PATCHED", "1")
	} else {
		_ = os.Setenv("PREFLIGHT_UI_REPORTER_PATCHED", "0")
	}
}

// --- Playwright -----------------------------------------------------------

var (
	pwHTMLReporterRE = regexp.MustCompile(
		`reporter\s*:\s*['"]html['"]|reporter\s*:\s*\[\s*['"]html['"]\s*\]`)
	pwVideoOnRE        = regexp.MustCompile(`video\s*:\s*['"]on['"]|video\s*:\s*['"]retain-on-failure['"]`)
	pwReuseExistingRE  = regexp.MustCompile(`reuseExistingServer\s*:\s*false`)
	pwReporterPatchSet = []struct{ from, to string }{
		{"reporter: 'html'", "reporter: process.env.CI ? 'dot' : 'html'"},
		{`reporter: "html"`, "reporter: process.env.CI ? 'dot' : 'html'"},
		{"reporter: ['html']", "reporter: process.env.CI ? 'dot' : 'html'"},
		{`reporter: ["html"]`, "reporter: process.env.CI ? 'dot' : 'html'"},
	}
)

func scanPlaywright(in *Input) []Finding {
	proj := in.ProjectDir
	cfg := ""
	for _, name := range []string{
		"playwright.config.ts",
		"playwright.config.js",
		"playwright.config.mjs",
		"playwright.config.cjs",
	} {
		if fileExists(proj, name) {
			cfg = filepath.Join(proj, name)
			break
		}
	}
	if cfg == "" {
		return nil
	}

	body, err := os.ReadFile(cfg)
	if err != nil {
		return nil
	}
	content := string(body)
	issues := 0
	var out []Finding

	// PW-1: html reporter (FAIL — auto-fix candidate).
	if pwHTMLReporterRE.MatchString(content) {
		out = append(out, playwrightFixReporter(in, cfg))
		issues++
	}
	// PW-2: video on / retain-on-failure (WARN only).
	if pwVideoOnRE.MatchString(content) {
		out = append(out, warn("UI Config (Playwright) — video recording",
			`playwright.config video='on' or 'retain-on-failure' produces large artifacts.
Consider: video: process.env.CI ? 'off' : 'retain-on-failure'`))
		issues++
	}
	// PW-3: webServer.reuseExistingServer: false (WARN only).
	if pwReuseExistingRE.MatchString(content) {
		out = append(out, warn("UI Config (Playwright) — reuseExistingServer: false",
			`playwright.config webServer.reuseExistingServer=false can cause the test runner
to hang if the dev server port is already in use.
Consider: reuseExistingServer: !process.env.CI`))
		issues++
	}
	if issues == 0 {
		out = append(out, pass("UI Config (Playwright)",
			fmt.Sprintf("No interactive-mode config issues detected in %s.", filepath.Base(cfg))))
	}
	return out
}

func playwrightFixReporter(in *Input, cfg string) Finding {
	proj := in.ProjectDir
	bakDir := in.GetenvDefault("PREFLIGHT_BAK_DIR",
		filepath.Join(proj, ".claude", "preflight_bak"))
	ts := time.Now().Format("20060102_150405")
	base := filepath.Base(cfg)
	bakFile := filepath.Join(bakDir, ts+"_"+base)

	// m136 knob takes precedence; legacy m55 PREFLIGHT_AUTO_FIX is the
	// fallback so existing user configs still work; default true.
	autoFix := in.Getenv("PREFLIGHT_UI_CONFIG_AUTO_FIX")
	if autoFix == "" {
		autoFix = in.GetenvDefault("PREFLIGHT_AUTO_FIX", "true")
	}
	if autoFix != "true" {
		setUIEnvExports("PW-1", base, false)
		return failF("UI Config (Playwright) — html reporter",
			fmt.Sprintf(`%s sets reporter: 'html'. Playwright's HTML reporter launches an
interactive serve-and-wait loop that is incompatible with Tekhton's timed gates.

REQUIRED MANUAL FIX:
  Change:  reporter: 'html'
  To:      reporter: process.env.CI ? 'dot' : 'html'

Or, in tekhton pipeline.conf:
  PLAYWRIGHT_HTML_OPEN=never
  CI=1  (forces non-interactive mode without changing source)

Auto-fix is disabled (PREFLIGHT_UI_CONFIG_AUTO_FIX=false, or legacy
PREFLIGHT_AUTO_FIX=false). Set either to true to allow Tekhton to patch
the config file automatically.`, base))
	}

	if err := os.MkdirAll(bakDir, 0o755); err != nil {
		setUIEnvExports("PW-1", base, false)
		return failF("UI Config (Playwright) — html reporter", fmt.Sprintf(
			"Failed to create backup dir %s. Skipping auto-patch.", bakDir))
	}
	original, err := os.ReadFile(cfg)
	if err != nil {
		setUIEnvExports("PW-1", base, false)
		return failF("UI Config (Playwright) — html reporter", fmt.Sprintf(
			"Failed to read %s: %v", base, err))
	}
	if err := os.WriteFile(bakFile, original, 0o644); err != nil {
		setUIEnvExports("PW-1", base, false)
		return failF("UI Config (Playwright) — html reporter", fmt.Sprintf(
			"Failed to create backup at %s. Skipping auto-patch.", relTo(bakFile, proj)))
	}

	patched := string(original)
	for _, p := range pwReporterPatchSet {
		patched = strings.ReplaceAll(patched, p.from, p.to)
	}
	if err := os.WriteFile(cfg, []byte(patched), 0o644); err != nil {
		setUIEnvExports("PW-1", base, false)
		return failF("UI Config (Playwright) — html reporter", fmt.Sprintf(
			"Failed to auto-patch %s. See manual fix instructions.\nBackup: %s",
			base, relTo(bakFile, proj)))
	}

	// m135 retention trim — best-effort.
	trimBackupDir(bakDir, retainCount(in))

	setUIEnvExports("PW-1", base, true)
	return fixed("UI Config (Playwright) — html reporter", fmt.Sprintf(
		`Auto-patched reporter: 'html' → CI-guarded form in %s.
Original saved to: %s
The gate will use 'dot' reporter in CI mode (no interactive server).
Review and commit the change when satisfied.`,
		base, relTo(bakFile, proj)))
}

func relTo(p, base string) string {
	r, err := filepath.Rel(base, p)
	if err != nil {
		return p
	}
	return r
}

func retainCount(in *Input) int {
	v := in.GetenvDefault("PREFLIGHT_BAK_RETAIN_COUNT", "10")
	n := 0
	_, _ = fmt.Sscanf(v, "%d", &n)
	if n < 0 {
		return 0
	}
	return n
}

// trimBackupDir keeps only the N most-recent timestamped backup files.
// Mirrors `_trim_preflight_bak_dir`; the filename format
// "<YYYYMMDD_HHMMSS>_<base>" guarantees lexicographic == chronological
// order so no time parsing is needed.
func trimBackupDir(dir string, retain int) {
	if retain == 0 {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	var files []string
	for _, e := range entries {
		if e.Type().IsRegular() {
			files = append(files, e.Name())
		}
	}
	if len(files) <= retain {
		return
	}
	// Sort ascending (oldest first), then remove the leading excess.
	strings.Join(files, "") // satisfy import; sort below
	sortStrings(files)
	excess := len(files) - retain
	for i := 0; i < excess; i++ {
		_ = os.Remove(filepath.Join(dir, files[i]))
	}
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j-1] > s[j]; j-- {
			s[j-1], s[j] = s[j], s[j-1]
		}
	}
}

// --- Cypress --------------------------------------------------------------

var (
	cyVideoTrueRE     = regexp.MustCompile(`video\s*:\s*true`)
	cyMochaReporterRE = regexp.MustCompile(`reporter\s*:\s*['"]mochawesome['"]`)
)

func scanCypress(in *Input) []Finding {
	proj := in.ProjectDir
	cfg := ""
	for _, name := range []string{"cypress.config.ts", "cypress.config.js", "cypress.config.mjs"} {
		if fileExists(proj, name) {
			cfg = filepath.Join(proj, name)
			break
		}
	}
	if cfg == "" {
		return nil
	}
	body, err := os.ReadFile(cfg)
	if err != nil {
		return nil
	}
	content := string(body)
	issues := 0
	var out []Finding

	if cyVideoTrueRE.MatchString(content) {
		out = append(out, warn("UI Config (Cypress) — video: true",
			`cypress.config has video: true (default). Video recording produces large artifacts.
Consider: video: !!process.env.CI === false`))
		issues++
	}
	if cyMochaReporterRE.MatchString(content) {
		if !strings.Contains(in.Getenv("UI_TEST_CMD"), "--exit") {
			out = append(out, warn("UI Config (Cypress) — mochawesome reporter",
				`cypress.config uses mochawesome reporter. Without --exit in UI_TEST_CMD, the
reporter process may not terminate.
Consider adding: --exit to UI_TEST_CMD in pipeline.conf`))
			issues++
		}
	}
	if issues == 0 {
		out = append(out, pass("UI Config (Cypress)",
			fmt.Sprintf("No interactive-mode config issues detected in %s.", filepath.Base(cfg))))
	}
	return out
}

// --- Jest / Vitest --------------------------------------------------------

var jvWatchRE = regexp.MustCompile(`(?m)^\s*(watch|watchAll)\s*:\s*true`)

func scanJestVitest(in *Input) []Finding {
	proj := in.ProjectDir
	cfg := ""
	for _, name := range []string{
		"vitest.config.ts", "vitest.config.js",
		"jest.config.ts", "jest.config.js", "jest.config.mjs",
	} {
		if fileExists(proj, name) {
			cfg = filepath.Join(proj, name)
			break
		}
	}
	if cfg == "" {
		return nil
	}
	body, err := os.ReadFile(cfg)
	if err != nil {
		return nil
	}
	content := string(body)
	if jvWatchRE.MatchString(content) {
		base := filepath.Base(cfg)
		setUIEnvExports("JV-1", base, false)
		return []Finding{failF("UI Config (Jest/Vitest) — watch mode enabled",
			fmt.Sprintf(`%s has watch: true or watchAll: true. Watch mode causes the test
process to run indefinitely, which will always trigger Tekhton's UI_TEST_TIMEOUT.

REQUIRED FIX — choose one:
  a) Remove watch: true from %s
  b) Add --run flag to TEST_CMD in pipeline.conf (Vitest: vitest run ...)
  c) Set CI=true in the environment (disables watch in most frameworks)

Tekhton does not auto-patch watch mode config. This requires deliberate choice.`,
				base, base))}
	}
	return []Finding{pass("UI Config (Jest/Vitest)",
		fmt.Sprintf("No watch-mode config issues detected in %s.", filepath.Base(cfg)))}
}
