package preflight

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestUIConfigCheck_NoUITestCmd_Skip(t *testing.T) {
	proj := t.TempDir()
	r := (UIConfigCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if len(r.Findings) != 0 {
		t.Errorf("expected no findings without UI_TEST_CMD; got %+v", r.Findings)
	}
}

func TestUIConfigCheck_PlaywrightHTMLReporter_AutoFix(t *testing.T) {
	proj := t.TempDir()
	bak := filepath.Join(proj, ".claude", "preflight_bak")
	cfg := filepath.Join(proj, "playwright.config.ts")
	src := "export default { reporter: 'html' }\n"
	if err := os.WriteFile(cfg, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env: map[string]string{
			"UI_TEST_CMD":                  "playwright test",
			"PREFLIGHT_UI_CONFIG_AUTO_FIX": "true",
			"PREFLIGHT_BAK_DIR":            bak,
		},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "UI Config (Playwright) — html reporter") != StatusFixed {
		t.Fatalf("expected fixed; got %+v", r.Findings)
	}
	patched, _ := os.ReadFile(cfg)
	if !strings.Contains(string(patched), "process.env.CI") {
		t.Errorf("config file not patched; got %s", patched)
	}
	entries, err := os.ReadDir(bak)
	if err != nil {
		t.Fatalf("backup dir missing: %v", err)
	}
	if len(entries) != 1 {
		t.Errorf("expected 1 backup file; got %d", len(entries))
	}
	if os.Getenv("PREFLIGHT_UI_REPORTER_PATCHED") != "1" {
		t.Errorf("PREFLIGHT_UI_REPORTER_PATCHED not set to 1")
	}
}

func TestUIConfigCheck_PlaywrightHTMLReporter_AutoFixDisabled_Fail(t *testing.T) {
	proj := t.TempDir()
	cfg := filepath.Join(proj, "playwright.config.ts")
	if err := os.WriteFile(cfg, []byte("export default { reporter: 'html' }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env: map[string]string{
			"UI_TEST_CMD":                  "playwright test",
			"PREFLIGHT_UI_CONFIG_AUTO_FIX": "false",
		},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "UI Config (Playwright) — html reporter") != StatusFail {
		t.Errorf("expected fail when auto-fix disabled; got %+v", r.Findings)
	}
}

func TestUIConfigCheck_PlaywrightClean_Pass(t *testing.T) {
	proj := t.TempDir()
	cfg := filepath.Join(proj, "playwright.config.ts")
	if err := os.WriteFile(cfg, []byte("export default { reporter: 'dot' }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env:        map[string]string{"UI_TEST_CMD": "playwright test"},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "UI Config (Playwright)") != StatusPass {
		t.Errorf("expected pass for clean config; got %+v", r.Findings)
	}
}

func TestUIConfigCheck_JestWatchTrue_Fail(t *testing.T) {
	proj := t.TempDir()
	cfg := filepath.Join(proj, "jest.config.js")
	if err := os.WriteFile(cfg, []byte("module.exports = {\n  watch: true,\n}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env:        map[string]string{"UI_TEST_CMD": "jest"},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "UI Config (Jest/Vitest) — watch mode enabled") != StatusFail {
		t.Errorf("expected fail for watch:true; got %+v", r.Findings)
	}
}

func TestUIConfigCheck_AuditDisabled_NoOp(t *testing.T) {
	proj := t.TempDir()
	cfg := filepath.Join(proj, "playwright.config.ts")
	if err := os.WriteFile(cfg, []byte("export default { reporter: 'html' }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env: map[string]string{
			"UI_TEST_CMD":                       "playwright test",
			"PREFLIGHT_UI_CONFIG_AUDIT_ENABLED": "false",
		},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if len(r.Findings) != 0 {
		t.Errorf("expected no findings when audit disabled; got %+v", r.Findings)
	}
}

// --- PW-2 / PW-3 -----------------------------------------------------------

// TestUIConfigCheck_PlaywrightVideoOn_Warn exercises rule PW-2: video:'on'
// or 'retain-on-failure' produces large artifacts and triggers a warn.
func TestUIConfigCheck_PlaywrightVideoOn_Warn(t *testing.T) {
	proj := t.TempDir()
	cfg := filepath.Join(proj, "playwright.config.ts")
	if err := os.WriteFile(cfg,
		[]byte("export default { use: { video: 'on' } }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env:        map[string]string{"UI_TEST_CMD": "playwright test"},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "UI Config (Playwright) — video recording") != StatusWarn {
		t.Errorf("expected warn for video:on; got %+v", r.Findings)
	}
}

// TestUIConfigCheck_PlaywrightReuseExistingFalse_Warn exercises rule PW-3:
// webServer.reuseExistingServer=false can cause hangs if the port is busy.
func TestUIConfigCheck_PlaywrightReuseExistingFalse_Warn(t *testing.T) {
	proj := t.TempDir()
	cfg := filepath.Join(proj, "playwright.config.ts")
	if err := os.WriteFile(cfg,
		[]byte("export default { webServer: { reuseExistingServer: false } }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env:        map[string]string{"UI_TEST_CMD": "playwright test"},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "UI Config (Playwright) — reuseExistingServer: false") != StatusWarn {
		t.Errorf("expected warn for reuseExistingServer:false; got %+v", r.Findings)
	}
}

// --- Cypress ---------------------------------------------------------------

// TestUIConfigCheck_CypressVideoTrue_Warn exercises rule CY-1: video:true
// in cypress.config produces large artifacts.
func TestUIConfigCheck_CypressVideoTrue_Warn(t *testing.T) {
	proj := t.TempDir()
	cfg := filepath.Join(proj, "cypress.config.ts")
	if err := os.WriteFile(cfg,
		[]byte("export default { video: true }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env:        map[string]string{"UI_TEST_CMD": "cypress run"},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "UI Config (Cypress) — video: true") != StatusWarn {
		t.Errorf("expected warn for cypress video:true; got %+v", r.Findings)
	}
}

// TestUIConfigCheck_CypressMochawesome_NoExit_Warn exercises rule CY-2:
// mochawesome reporter without --exit in UI_TEST_CMD may not terminate.
func TestUIConfigCheck_CypressMochawesome_NoExit_Warn(t *testing.T) {
	proj := t.TempDir()
	cfg := filepath.Join(proj, "cypress.config.ts")
	if err := os.WriteFile(cfg,
		[]byte("export default { reporter: 'mochawesome' }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env:        map[string]string{"UI_TEST_CMD": "cypress run"},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "UI Config (Cypress) — mochawesome reporter") != StatusWarn {
		t.Errorf("expected warn for mochawesome without --exit; got %+v", r.Findings)
	}
}

// TestUIConfigCheck_CypressMochawesome_WithExit_Pass exercises the CY-2
// suppression path: when --exit is present in UI_TEST_CMD the mochawesome
// warning is suppressed and the config is treated as clean (pass).
func TestUIConfigCheck_CypressMochawesome_WithExit_Pass(t *testing.T) {
	proj := t.TempDir()
	cfg := filepath.Join(proj, "cypress.config.ts")
	if err := os.WriteFile(cfg,
		[]byte("export default { reporter: 'mochawesome' }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env:        map[string]string{"UI_TEST_CMD": "cypress run --exit"},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "UI Config (Cypress) — mochawesome reporter") != "" {
		t.Errorf("expected mochawesome warning suppressed with --exit; got %+v", r.Findings)
	}
	if findStatusByName(r.Findings, "UI Config (Cypress)") != StatusPass {
		t.Errorf("expected pass for clean cypress config with --exit; got %+v", r.Findings)
	}
}

// TestUIConfigCheck_CypressClean_Pass verifies the cypress happy path: a
// config file with no detected issues produces a single StatusPass finding.
func TestUIConfigCheck_CypressClean_Pass(t *testing.T) {
	proj := t.TempDir()
	cfg := filepath.Join(proj, "cypress.config.ts")
	if err := os.WriteFile(cfg,
		[]byte("export default { baseUrl: 'http://localhost:3000' }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env:        map[string]string{"UI_TEST_CMD": "cypress run"},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "UI Config (Cypress)") != StatusPass {
		t.Errorf("expected pass for clean cypress config; got %+v", r.Findings)
	}
}

// --- Jest / Vitest ---------------------------------------------------------

// TestUIConfigCheck_JestClean_Pass verifies the jest happy path: a jest
// config with no watch mode produces a single StatusPass finding.
func TestUIConfigCheck_JestClean_Pass(t *testing.T) {
	proj := t.TempDir()
	cfg := filepath.Join(proj, "jest.config.js")
	if err := os.WriteFile(cfg,
		[]byte("module.exports = { testEnvironment: 'node' }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env:        map[string]string{"UI_TEST_CMD": "jest"},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "UI Config (Jest/Vitest)") != StatusPass {
		t.Errorf("expected pass for clean jest config; got %+v", r.Findings)
	}
}

// TestUIConfigCheck_VitestWatchTrue_Fail verifies that vitest.config.ts
// with watch:true triggers the same JV-1 fail rule as jest.config.js.
// vitest.config.ts is first in the scanner's priority list.
func TestUIConfigCheck_VitestWatchTrue_Fail(t *testing.T) {
	proj := t.TempDir()
	cfg := filepath.Join(proj, "vitest.config.ts")
	if err := os.WriteFile(cfg,
		[]byte("export default defineConfig({\n  watch: true,\n})\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env:        map[string]string{"UI_TEST_CMD": "vitest"},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "UI Config (Jest/Vitest) — watch mode enabled") != StatusFail {
		t.Errorf("expected fail for vitest watch:true; got %+v", r.Findings)
	}
}

// --- Contract vars ---------------------------------------------------------

// TestUIConfigCheck_ContractVars_SetOnHTMLDetect verifies the four
// PREFLIGHT_UI_* env var exports that downstream consumers (UI gate
// normaliser, diagnose rules, RUN_SUMMARY) depend on.
func TestUIConfigCheck_ContractVars_SetOnHTMLDetect(t *testing.T) {
	// Clear first — t.Setenv saves the original and restores on cleanup.
	for _, k := range []string{
		"PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED",
		"PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE",
		"PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE",
		"PREFLIGHT_UI_REPORTER_PATCHED",
	} {
		t.Setenv(k, "")
	}
	proj := t.TempDir()
	cfg := filepath.Join(proj, "playwright.config.ts")
	if err := os.WriteFile(cfg,
		[]byte("export default { reporter: 'html' }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env: map[string]string{
			"UI_TEST_CMD":                  "playwright test",
			"PREFLIGHT_UI_CONFIG_AUTO_FIX": "false",
		},
	}
	(UIConfigCheck{}).Run(context.Background(), in)
	if os.Getenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED") != "1" {
		t.Error("PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED not set to 1")
	}
	if os.Getenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE") != "PW-1" {
		t.Errorf("PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE = %q, want PW-1",
			os.Getenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE"))
	}
	if os.Getenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE") == "" {
		t.Error("PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE is empty, want the config filename")
	}
	if os.Getenv("PREFLIGHT_UI_REPORTER_PATCHED") != "0" {
		t.Errorf("PREFLIGHT_UI_REPORTER_PATCHED = %q, want 0 (auto-fix disabled)",
			os.Getenv("PREFLIGHT_UI_REPORTER_PATCHED"))
	}
}

// TestUIConfigCheck_ContractVars_ClearedOnRestart verifies that
// resetUIEnvExports clears the contract vars at the start of every Run
// invocation so stale values from a previous check cannot bleed through.
func TestUIConfigCheck_ContractVars_ClearedOnRestart(t *testing.T) {
	// Seed with stale values.
	for k, v := range map[string]string{
		"PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED": "1",
		"PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE":     "OLD",
		"PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE":     "old.ts",
		"PREFLIGHT_UI_REPORTER_PATCHED":            "1",
	} {
		t.Setenv(k, v)
	}
	// Run on a project with no UI_TEST_CMD — exits after resetUIEnvExports.
	(UIConfigCheck{}).Run(context.Background(), &Input{ProjectDir: t.TempDir()})
	for _, k := range []string{
		"PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED",
		"PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE",
		"PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE",
		"PREFLIGHT_UI_REPORTER_PATCHED",
	} {
		if got := os.Getenv(k); got != "" {
			t.Errorf("expected %s cleared after reset; got %q", k, got)
		}
	}
}

// --- Backup retention ------------------------------------------------------

// TestUIConfigCheck_BackupRetention_TrimsOldFiles verifies the
// PREFLIGHT_BAK_RETAIN_COUNT knob: after auto-patching, old backup files
// exceeding the retain limit are pruned.
func TestUIConfigCheck_BackupRetention_TrimsOldFiles(t *testing.T) {
	proj := t.TempDir()
	bak := filepath.Join(proj, ".claude", "preflight_bak")
	if err := os.MkdirAll(bak, 0o755); err != nil {
		t.Fatal(err)
	}
	// Pre-populate 5 old backup files with chronologically ascending names.
	for i := 0; i < 5; i++ {
		name := fmt.Sprintf("2026010%d_120000_playwright.config.ts", i)
		if err := os.WriteFile(filepath.Join(bak, name), []byte("old"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cfg := filepath.Join(proj, "playwright.config.ts")
	if err := os.WriteFile(cfg,
		[]byte("export default { reporter: 'html' }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env: map[string]string{
			"UI_TEST_CMD":                  "playwright test",
			"PREFLIGHT_UI_CONFIG_AUTO_FIX": "true",
			"PREFLIGHT_BAK_DIR":            bak,
			"PREFLIGHT_BAK_RETAIN_COUNT":   "3",
		},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "UI Config (Playwright) — html reporter") != StatusFixed {
		t.Fatalf("expected fixed; got %+v", r.Findings)
	}
	// 5 old + 1 new = 6 total before trim; retain=3 leaves only the 3 newest.
	entries, err := os.ReadDir(bak)
	if err != nil {
		t.Fatalf("read backup dir: %v", err)
	}
	if len(entries) > 3 {
		names := make([]string, len(entries))
		for i, e := range entries {
			names[i] = e.Name()
		}
		t.Errorf("expected ≤3 backup files after retention trim; got %d: %v",
			len(entries), names)
	}
}

// TestUIConfigCheck_PlaywrightArrayReporter_AutoFix exercises the array form
// of the html reporter (reporter: ['html']) which PW-1 also matches.
func TestUIConfigCheck_PlaywrightArrayReporter_AutoFix(t *testing.T) {
	proj := t.TempDir()
	bak := filepath.Join(proj, ".claude", "preflight_bak")
	cfg := filepath.Join(proj, "playwright.config.ts")
	if err := os.WriteFile(cfg,
		[]byte("export default { reporter: ['html'] }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	in := &Input{
		ProjectDir: proj,
		Env: map[string]string{
			"UI_TEST_CMD":                  "playwright test",
			"PREFLIGHT_UI_CONFIG_AUTO_FIX": "true",
			"PREFLIGHT_BAK_DIR":            bak,
		},
	}
	r := (UIConfigCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "UI Config (Playwright) — html reporter") != StatusFixed {
		t.Fatalf("expected fixed for array-form html reporter; got %+v", r.Findings)
	}
	patched, _ := os.ReadFile(cfg)
	if strings.Contains(string(patched), "['html']") {
		t.Errorf("expected array-form patched away; got %s", patched)
	}
}
