// Package preflight is the Go-side orchestrator for the pre-flight check
// chain. Before m22 the runner shelled out to lib/preflight.sh once per
// run; m22 ports the registry, run loop, and all five check families into
// Go. The bash files (lib/preflight*.sh) are deleted as part of the same
// milestone — there is no per-check shim equivalent of m21's finalize
// dispatcher because preflight checks have flat dependencies (env binaries,
// file detection, shell commands), so the whole subsystem ports in one
// shot.
//
// Output parity is non-negotiable: dashboard parsers (lib/dashboard_parsers.sh,
// still bash through m23) read PREFLIGHT_REPORT.md by structure, so the
// report format must stay byte-identical. The parity gate
// (tests/test_preflight_parity.sh) diffs Go output against frozen bash
// baselines across green-path, env-only-fail, and ui-config-auto-patch
// scenarios.
//
// Check ordering is load-bearing — see checkOrder below. An order-mismatch
// test in orchestrator_test.go fails red if the slice drifts.
package preflight

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Status is the per-finding verdict the bash side encoded as the status
// string passed to _pf_record. The four values map 1:1 to the bash glyphs:
//
//	Pass  → "✓"   (passed check)
//	Warn  → "⚠"   (non-blocking issue)
//	Fail  → "✗"   (blocking issue)
//	Fixed → "🔧"  (auto-remediation succeeded)
//
// Skip is a Go addition for unit tests that need to express "check did not
// apply" without producing a report entry; the report writer treats Skip
// as a no-op.
type Status string

const (
	StatusPass  Status = "pass"
	StatusWarn  Status = "warn"
	StatusFail  Status = "fail"
	StatusFixed Status = "fixed"
	StatusSkip  Status = "skip"
)

// Finding is one row in the PREFLIGHT_REPORT.md report — equivalent to one
// invocation of _pf_record on the bash side. Name + Detail are written
// inside a "### ⟨glyph⟩ Name" block followed by the Detail body. AutoFix is
// populated when the check ran an auto-remediation command; it surfaces in
// the report body, not as a separate column.
type Finding struct {
	Name   string
	Status Status
	Detail string
}

// Result is what a Check returns from Run — one or more findings plus an
// optional services table for the M56 services check. Most checks return a
// flat []Finding; ServicesCheck additionally populates ServiceRows which
// the report writer renders as a markdown table under "## Services".
type Result struct {
	Findings    []Finding
	ServiceRows []ServiceRow // Only populated by ServicesCheck.
}

// ServiceRow is one entry in the "## Services" table. Mirrors the bash
// _PF_SERVICES entry shape (display|port|source|status|default_port).
type ServiceRow struct {
	Display     string
	Port        string
	Source      string
	Status      string // "running" | "not_running" | "unknown"
	DefaultPort string
}

// Input is the per-run bundle every check receives. ProjectDir is the
// caller's target project (PROJECT_DIR), TekhtonHome is the binary's
// install dir (TEKHTON_HOME). Env carries the config-derived knobs
// (UI_TEST_CMD, ANALYZE_CMD, PREFLIGHT_UI_CONFIG_AUTO_FIX, …) so checks
// don't reach into os.Getenv directly — tests can substitute the map.
type Input struct {
	ProjectDir  string
	TekhtonHome string
	Env         map[string]string

	// detected languages cache, populated lazily by Foundation/Services.
	// Maps lowercase language name → manifest path (sentinel value;
	// presence is the signal).
	languages map[string]string

	// detected test frameworks cache, populated lazily by Foundation.
	// Maps lowercase framework name → manifest path.
	testFrameworks map[string]string
}

// Getenv reads a config key from the per-run env map, falling back to the
// process environment so checks behave the same way whether the caller is
// the runner (populates Env from pipeline.conf) or the standalone CLI
// subcommand (relies on os.Environ).
func (in *Input) Getenv(key string) string {
	if in.Env != nil {
		if v, ok := in.Env[key]; ok {
			return v
		}
	}
	return os.Getenv(key)
}

// GetenvDefault is Getenv with a fallback. Mirrors the bash `${VAR:-default}`
// idiom used pervasively across the preflight scripts.
func (in *Input) GetenvDefault(key, fallback string) string {
	v := in.Getenv(key)
	if v == "" {
		return fallback
	}
	return v
}

// Check is the interface each preflight check family implements. The bash
// side called individual _preflight_check_* functions; Go groups them
// into five families (env, foundation, services, services_infer, ui_audit)
// that each implement Check.
type Check interface {
	Name() string
	Run(ctx context.Context, in *Input) Result
}

// checkOrder is the authoritative registration order. The order-mismatch
// guard in orchestrator_test.go fails red if this slice drifts. The
// per-family order is interleaved on the bash side
// (lib/preflight.sh:run_preflight_checks); the Go orchestrator groups by
// family for report output, so the registered order here is the order
// findings appear in PREFLIGHT_REPORT.md.
var checkOrder = []string{
	"foundation",
	"ui_audit",
	"env",
	"services_infer",
	"services",
}

// CheckOrder returns the canonical check registration order. Exported so
// the order-mismatch test and parity tooling can compare against it.
func CheckOrder() []string {
	out := make([]string, len(checkOrder))
	copy(out, checkOrder)
	return out
}

// goNativeChecks is the factory map keyed on check name. Adding a new
// family means: (1) implement Check in a new file, (2) register the
// factory here, (3) add the name to checkOrder.
var goNativeChecks = map[string]func() Check{
	"foundation":     func() Check { return &FoundationCheck{} },
	"ui_audit":       func() Check { return &UIConfigCheck{} },
	"env":            func() Check { return &EnvCheck{} },
	"services_infer": func() Check { return &ServicesInferCheck{} },
	"services":       func() Check { return &ServicesCheck{} },
}

// Orchestrator owns the registry and run loop. Constructed by
// NewOrchestrator with the canonical five-check registration; tests
// substitute fakes into Checks directly.
type Orchestrator struct {
	Checks      []Check
	ProjectDir  string
	TekhtonHome string

	// ReportPath overrides the default report location.
	ReportPath string

	// Log is where the orchestrator writes diagnostic output. Defaults to
	// os.Stderr.
	Log io.Writer

	// Now overrides the clock for deterministic report timestamps in tests.
	Now func() time.Time

	// findings accumulates across checks for report rendering.
	findings    []Finding
	serviceRows []ServiceRow

	// failedCount / warnCount / passCount / fixedCount are the summary
	// counters surfaced via HasBlockers / SummaryLine. The bash side kept
	// the same four counters as _PF_PASS / _PF_WARN / _PF_FAIL / _PF_REMEDIATED.
	passCount  int
	warnCount  int
	failCount  int
	fixedCount int
}

// NewOrchestrator builds an Orchestrator with the canonical five-check
// registration. ProjectDir / TekhtonHome anchor every check's per-run
// Input; both must be set on the returned struct before Run is called
// (NewOrchestrator stores them on the receiver so the caller does not need
// to thread them through Input).
func NewOrchestrator(tekhtonHome, projectDir string) *Orchestrator {
	o := &Orchestrator{
		TekhtonHome: tekhtonHome,
		ProjectDir:  projectDir,
		Log:         os.Stderr,
		Now:         time.Now,
	}
	o.Checks = make([]Check, 0, len(checkOrder))
	for _, name := range checkOrder {
		ctor, ok := goNativeChecks[name]
		if !ok {
			continue
		}
		o.Checks = append(o.Checks, ctor())
	}
	return o
}

// reportPath returns the configured ReportPath or the default under the
// project directory.
func (o *Orchestrator) reportPath() string {
	if o.ReportPath != "" {
		return o.ReportPath
	}
	tekhtonDir := o.envOr("TEKHTON_DIR", ".tekhton")
	rep := o.envOr("PREFLIGHT_REPORT_FILE", filepath.Join(tekhtonDir, "PREFLIGHT_REPORT.md"))
	if filepath.IsAbs(rep) {
		return rep
	}
	return filepath.Join(o.ProjectDir, rep)
}

func (o *Orchestrator) envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// HasBlockers returns true when at least one check produced a fail-status
// finding. The runner uses this to decide whether to abort the pipeline.
func (o *Orchestrator) HasBlockers() bool {
	if o.failCount > 0 {
		return true
	}
	if o.warnCount > 0 && os.Getenv("PREFLIGHT_FAIL_ON_WARN") == "true" {
		return true
	}
	return false
}

// SummaryLine returns the one-line summary the bash side logged after
// run_preflight_checks (e.g. "Pre-flight: 3 passed, 1 warned, 0 failed,
// 0 auto-fixed").
func (o *Orchestrator) SummaryLine() string {
	return fmt.Sprintf("Pre-flight: %d passed, %d warned, %d failed, %d auto-fixed",
		o.passCount, o.warnCount, o.failCount, o.fixedCount)
}

// Run drives the chain. Returns the path of the written report (empty
// string when no checks were applicable and the report was skipped — the
// bash side skipped the report entirely in that case).
func (o *Orchestrator) Run(ctx context.Context) (string, error) {
	if !preflightEnabled() {
		return "", nil
	}
	o.findings = nil
	o.serviceRows = nil
	o.passCount, o.warnCount, o.failCount, o.fixedCount = 0, 0, 0, 0

	in := &Input{
		ProjectDir:  o.ProjectDir,
		TekhtonHome: o.TekhtonHome,
	}
	// Stable iteration order — Checks slice is already in registration
	// order via NewOrchestrator.
	for _, ch := range o.Checks {
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		default:
		}
		res := ch.Run(ctx, in)
		o.recordResult(res)
	}

	total := o.passCount + o.warnCount + o.failCount + o.fixedCount
	if total == 0 {
		// Bash side also returns silently with no report file written.
		return "", nil
	}

	path := o.reportPath()
	if err := o.writeReport(path); err != nil {
		return path, fmt.Errorf("preflight: write report: %w", err)
	}
	return path, nil
}

func (o *Orchestrator) recordResult(r Result) {
	for _, f := range r.Findings {
		switch f.Status {
		case StatusPass:
			o.passCount++
		case StatusWarn:
			o.warnCount++
		case StatusFail:
			o.failCount++
		case StatusFixed:
			o.fixedCount++
		case StatusSkip:
			continue
		}
		o.findings = append(o.findings, f)
	}
	o.serviceRows = append(o.serviceRows, r.ServiceRows...)
}

func preflightEnabled() bool {
	v := strings.ToLower(strings.TrimSpace(os.Getenv("PREFLIGHT_ENABLED")))
	if v == "" {
		return true
	}
	return v == "true" || v == "1" || v == "yes"
}

// writeReport renders PREFLIGHT_REPORT.md with the same structure the bash
// _emit_preflight_report function produced. Sections in order:
//
//	# Pre-flight Report — <timestamp>
//	## Summary
//	<glyph-line>
//	## Checks
//	<per-finding block>
//	[## Services] (only when ServiceRows present)
//
// The timestamp line is the only date-bearing content; the parity gate
// normalises it before diffing.
func (o *Orchestrator) writeReport(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	var buf strings.Builder
	ts := o.Now().Format("2006-01-02 15:04:05")
	fmt.Fprintf(&buf, "# Pre-flight Report — %s\n\n", ts)
	buf.WriteString("## Summary\n")
	fmt.Fprintf(&buf, "✓ %d passed  ⚠ %d warned  ✗ %d failed  🔧 %d auto-fixed\n\n",
		o.passCount, o.warnCount, o.failCount, o.fixedCount)
	buf.WriteString("## Checks\n\n")
	for _, f := range o.findings {
		buf.WriteString("### ")
		buf.WriteString(glyphFor(f.Status))
		buf.WriteString(" ")
		buf.WriteString(f.Name)
		buf.WriteString("\n")
		buf.WriteString(f.Detail)
		buf.WriteString("\n\n")
	}
	if len(o.serviceRows) > 0 {
		writeServicesSection(&buf, o.serviceRows)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(buf.String()), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func glyphFor(s Status) string {
	switch s {
	case StatusPass:
		return "✓"
	case StatusWarn:
		return "⚠"
	case StatusFail:
		return "✗"
	case StatusFixed:
		return "🔧"
	}
	return "?"
}

func writeServicesSection(buf *strings.Builder, rows []ServiceRow) {
	buf.WriteString("## Services\n\n")
	buf.WriteString("| Service | Port | Status | Source |\n")
	buf.WriteString("|---------|------|--------|--------|\n")
	// Sort by display name for deterministic output across runs; the bash
	// side iterated _PF_SERVICES in insertion order, which depended on
	// inference call order — for parity we sort.
	sorted := make([]ServiceRow, len(rows))
	copy(sorted, rows)
	sort.SliceStable(sorted, func(i, j int) bool {
		return sorted[i].Display < sorted[j].Display
	})
	for _, r := range sorted {
		indicator := "— Unknown"
		switch r.Status {
		case "running":
			indicator = "✓ Running"
		case "not_running":
			indicator = "✗ Not running"
		}
		fmt.Fprintf(buf, "| %s | %s | %s | %s |\n",
			r.Display, r.Port, indicator, r.Source)
	}
	buf.WriteString("\n")
}
