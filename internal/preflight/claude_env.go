package preflight

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// ClaudeEnvCheck validates the two pieces of caller-side claude state that
// silently break supervised runs when broken:
//
//  1. .claude/settings.json — malformed JSON makes claude refuse to load
//     ANY tool config, including allowedTools and permission rules. The
//     symptom is an agent that has no Write/Edit access and burns turns
//     on Read-only operations (which looks identical to "the model just
//     decided not to do anything"). Caught early as a hard fail.
//
//  2. claude CLI version — Tekhton ships with a tested compatibility
//     band. Versions below CLAUDE_MIN_VERSION lack flags or event-stream
//     fields the supervisor depends on; versions in CLAUDE_BAD_VERSIONS
//     have known regressions. Both are warn-only by default (the run
//     might still succeed); flip PREFLIGHT_FAIL_ON_WARN=true to make
//     them blocking.
type ClaudeEnvCheck struct{}

func (ClaudeEnvCheck) Name() string { return "claude_env" }

func (ClaudeEnvCheck) Run(_ context.Context, in *Input) Result {
	// Only applicable when the target project is genuinely set up for
	// Claude / Tekhton. We can't just look for `.claude/` itself because
	// the ui_audit check creates `.claude/preflight_bak/` as a side
	// effect of its auto-patch, so a brand-new project running through
	// preflight would falsely look "Claude-managed" after that check
	// fired. Gate on a marker that only a real setup would have:
	// settings.json (Claude), pipeline.conf (Tekhton), or agents/.
	dot := filepath.Join(in.ProjectDir, ".claude")
	managed := fileExists(dot, "settings.json") ||
		fileExists(dot, "pipeline.conf") ||
		dirExists(filepath.Join(dot, "agents"))
	if !managed {
		return Result{}
	}
	var r Result
	r.Findings = append(r.Findings, checkClaudeSettingsJSON(in)...)
	r.Findings = append(r.Findings, checkClaudeVersion(in)...)
	return r
}

// checkClaudeSettingsJSON validates .claude/settings.json parses if it
// exists. We do NOT validate the schema — only that it's valid JSON,
// because the schema evolves with each CLI release and we'd false-alarm
// every time claude adds a new top-level key.
func checkClaudeSettingsJSON(in *Input) []Finding {
	path := filepath.Join(in.ProjectDir, ".claude", "settings.json")
	st, err := os.Stat(path)
	if err != nil || st.IsDir() {
		return nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return []Finding{warn("Claude settings.json",
			fmt.Sprintf("Could not read %s: %v", path, err))}
	}
	trimmed := strings.TrimSpace(string(b))
	if trimmed == "" {
		// Empty file is fine — claude treats it as no overrides.
		return []Finding{pass("Claude settings.json", path+" is empty (no overrides).")}
	}
	var probe map[string]any
	if err := json.Unmarshal(b, &probe); err != nil {
		return []Finding{failF("Claude settings.json",
			fmt.Sprintf("%s is not valid JSON: %v. Claude will refuse to load tool config — fix or rename before continuing.", path, err))}
	}
	return []Finding{pass("Claude settings.json", path+" parses as valid JSON.")}
}

// checkClaudeVersion runs `claude --version` and compares against the
// caller-configurable compatibility band. Skips silently if the binary is
// not on PATH (a Tekhton invocation without claude installed is an
// entirely different failure mode — the supervisor will surface it on
// the first run_agent call).
//
// m21 — Goal 4: when the active PROVIDER spec does not include "claude",
// emit a StatusSkip finding instead of exec'ing the binary. The post-June-15
// cutover state means a zero-claude run must truly exec zero claude — the
// preflight liveness check would otherwise fire on every adjacent project.
//
// Min version is taken from CLAUDE_MIN_VERSION (default 2.1.140 — the
// release that introduced `--no-session-persistence` and the
// permission_denials[] field the V4 supervisor depends on). Bad versions
// is a comma-separated list in CLAUDE_BAD_VERSIONS (default empty).
func checkClaudeVersion(in *Input) []Finding {
	if !providerSpecIncludesClaude(in.GetenvDefault("PROVIDER", "codex,claude")) {
		return []Finding{skip("Claude CLI version",
			"PROVIDER spec does not include claude — skipping liveness check.")}
	}
	bin := in.GetenvDefault("TEKHTON_CLAUDE_BIN", "claude")
	if _, err := exec.LookPath(bin); err != nil {
		return nil
	}
	out, err := exec.Command(bin, "--version").Output()
	if err != nil {
		return []Finding{warn("Claude CLI version",
			fmt.Sprintf("`%s --version` failed: %v", bin, err))}
	}
	// Format: "2.1.146 (Claude Code)\n"
	version := strings.Fields(strings.TrimSpace(string(out)))[0]
	if version == "" {
		return []Finding{warn("Claude CLI version",
			fmt.Sprintf("could not parse version from `%s --version` output: %q", bin, string(out)))}
	}

	minVer := in.GetenvDefault("CLAUDE_MIN_VERSION", "2.1.140")
	if cmp, ok := compareSemver(version, minVer); ok && cmp < 0 {
		return []Finding{warn("Claude CLI version",
			fmt.Sprintf("claude %s is below the tested minimum %s. The supervisor relies on flags + event fields that may be missing. Set CLAUDE_MIN_VERSION to silence.",
				version, minVer))}
	}

	bad := in.GetenvDefault("CLAUDE_BAD_VERSIONS", "")
	for _, v := range strings.Split(bad, ",") {
		v = strings.TrimSpace(v)
		if v == "" {
			continue
		}
		if v == version {
			return []Finding{warn("Claude CLI version",
				fmt.Sprintf("claude %s is in CLAUDE_BAD_VERSIONS. A known regression has been reported against this build — upgrade or downgrade before continuing.", version))}
		}
	}
	return []Finding{pass("Claude CLI version",
		fmt.Sprintf("claude %s is within the tested compatibility band (>= %s).", version, minVer))}
}

// compareSemver returns -1, 0, 1 for a<b, a==b, a>b across three-segment
// dotted versions like "2.1.146". Returns ok=false when either side fails
// to parse — callers treat that as "skip the comparison" so a weird claude
// build string can't false-alarm preflight.
func compareSemver(a, b string) (int, bool) {
	pa, ok := parseSemver(a)
	if !ok {
		return 0, false
	}
	pb, ok := parseSemver(b)
	if !ok {
		return 0, false
	}
	for i := 0; i < 3; i++ {
		if pa[i] < pb[i] {
			return -1, true
		}
		if pa[i] > pb[i] {
			return 1, true
		}
	}
	return 0, true
}

// providerSpecIncludesClaude reports whether the comma-separated PROVIDER
// spec contains the "claude" provider. Matches m21's chain-membership gate
// semantics: the default ("codex,claude") includes claude, a spec like
// "codex" alone does not, "qwen-local" does not, "codex,claude" does.
// Whitespace around items is tolerated.
func providerSpecIncludesClaude(spec string) bool {
	for _, item := range strings.Split(spec, ",") {
		if strings.TrimSpace(item) == "claude" {
			return true
		}
	}
	return false
}

func parseSemver(v string) ([3]int, bool) {
	var out [3]int
	parts := strings.SplitN(strings.TrimPrefix(v, "v"), ".", 3)
	if len(parts) != 3 {
		return out, false
	}
	for i, p := range parts {
		// Trim anything after the first non-digit (e.g. "146-beta1" → "146").
		end := 0
		for end < len(p) && p[end] >= '0' && p[end] <= '9' {
			end++
		}
		n, err := strconv.Atoi(p[:end])
		if err != nil {
			return out, false
		}
		out[i] = n
	}
	return out, true
}
