// BashRuleAdapter — m32.1 transition shim.
//
// The adapter wraps the legacy bash rule registry (18 rules across
// lib/diagnose_rules*.sh) in the Rule / RuleProvider interfaces so the Go
// engine can run end-to-end while the bash rules remain canonical. m32.2
// replaces this entire file with a Go-native rules registry.
//
// Round-tripping. The bash rules read the _DIAG_* module-state globals
// directly. To call a rule from Go we exec a tiny bash wrapper that:
//
//  1. Sources common.sh + diagnose_helpers.sh + diagnose_rules.sh and
//     companions so the bash globals are declared.
//  2. Sets every _DIAG_* global from the Go *Context fields (env vars).
//  3. Invokes the named rule function.
//  4. Prints DIAG_CLASSIFICATION / DIAG_CONFIDENCE / DIAG_SUGGESTIONS to
//     stdout as a structured `KEY=VALUE` block.
//  5. Exits 0 on match, 1 on no-match (mirrors the bash rule contract).
//
// Large _DIAG_CAUSAL_EVENTS payloads (the bash rules can see hundreds of
// KB on a long run) bypass the env-var copy via a tempfile + pointer env
// var `_DIAG_CAUSAL_EVENTS_FILE`; the bash wrapper reads the file when
// the pointer is set.

package diagnose

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// envVarRoundTripLimit is the largest single _DIAG_* env var the adapter
// will pass directly. Above this size the adapter writes the value to a
// tempfile and passes `<NAME>_FILE=/tmp/...` instead.
const envVarRoundTripLimit = 128 * 1024

// bashRuleRegistryOrder is the priority-ordered list mirrored from
// lib/diagnose_rules_registry.sh. ORDER MATTERS — classify_failure_diag
// walks the bash array top-down and stops at first match; the Go-side
// order MUST match byte-for-byte.
//
// When lib/diagnose_rules_registry.sh changes (rare — it has been stable
// since M133), update this list and the order-mismatch unit test that
// asserts the list matches the bash file at compile time will fail red.
var bashRuleRegistryOrder = []string{
	"_rule_ui_gate_interactive_reporter",
	"_rule_preflight_interactive_config",
	"_rule_build_fix_exhausted",
	"_rule_build_failure",
	"_rule_max_turns",
	"_rule_review_loop",
	"_rule_security_halt",
	"_rule_intake_clarity",
	"_rule_quota_exhausted",
	"_rule_stuck_loop",
	"_rule_mixed_classification",
	"_rule_turn_exhaustion",
	"_rule_split_depth",
	"_rule_transient_error",
	"_rule_test_audit_failure",
	"_rule_migration_crash",
	"_rule_version_mismatch",
	"_rule_unknown",
}

// BashRuleAdapter implements RuleProvider by exec'ing the bash rule
// functions one at a time. TekhtonHome is required (the bash sources
// pinned to ${TEKHTON_HOME}/lib/...). BashPath defaults to "bash".
type BashRuleAdapter struct {
	TekhtonHome string
	BashPath    string

	// Exec is the command runner; defaults to exec.Command. Tests inject
	// a stub that emits canned (stdout, exitCode) without spawning bash.
	Exec func(name string, args ...string) *exec.Cmd
}

// Rules returns the priority-ordered slice of Rule wrappers.
func (a *BashRuleAdapter) Rules() []Rule {
	out := make([]Rule, 0, len(bashRuleRegistryOrder))
	for _, name := range bashRuleRegistryOrder {
		out = append(out, &bashRule{name: name, adapter: a})
	}
	return out
}

// BashRuleRegistryOrder returns the exact bash registry priority order
// the adapter wraps. Exposed for the order-mismatch parity test.
func BashRuleRegistryOrder() []string {
	out := make([]string, len(bashRuleRegistryOrder))
	copy(out, bashRuleRegistryOrder)
	return out
}

type bashRule struct {
	name    string
	adapter *BashRuleAdapter
}

func (r *bashRule) Name() string { return r.name }

func (r *bashRule) Match(c *Context) (Diagnosis, bool) {
	if r.adapter == nil || c == nil {
		return Diagnosis{}, false
	}
	stdout, matched, err := r.adapter.invokeRule(r.name, c)
	if err != nil || !matched {
		return Diagnosis{}, false
	}
	return parseRuleOutput(stdout, r.name, c.Stage), true
}

// invokeRule exec's the bash wrapper for one rule. Returns the rule's
// stdout, a bool indicating whether the rule reported a match (exit 0),
// and any subprocess error.
func (a *BashRuleAdapter) invokeRule(ruleName string, c *Context) (string, bool, error) {
	bash := a.BashPath
	if bash == "" {
		bash = "bash"
	}
	if a.TekhtonHome == "" {
		return "", false, fmt.Errorf("BashRuleAdapter: TekhtonHome is required")
	}

	env, cleanup, err := a.buildEnv(c)
	if err != nil {
		return "", false, err
	}
	defer cleanup()

	script := bashWrapperScript(ruleName)
	exe := a.Exec
	if exe == nil {
		exe = exec.Command
	}
	cmd := exe(bash, "-c", script)
	cmd.Env = env
	cmd.Stdin = nil
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	runErr := cmd.Run()
	matched := runErr == nil
	if runErr != nil {
		// Non-zero exit is "no match" — not a subprocess error. The bash
		// rule contract uses `return 1` for the no-match path.
		if _, ok := runErr.(*exec.ExitError); ok {
			return stdout.String(), false, nil
		}
		return stdout.String(), false, runErr
	}
	return stdout.String(), matched, nil
}

// buildEnv prepares the env-var slice and any tempfile cleanup the
// wrapper needs. The cleanup func always runs — it removes any
// tempfile pointers created for large _DIAG_* values.
func (a *BashRuleAdapter) buildEnv(c *Context) ([]string, func(), error) {
	env := os.Environ()
	env = appendKV(env, "TEKHTON_HOME", a.TekhtonHome)
	if c.ProjectDir != "" {
		env = appendKV(env, "PROJECT_DIR", c.ProjectDir)
	}

	// Scalar _DIAG_* fields — direct env var population.
	env = appendKV(env, "_DIAG_PIPELINE_OUTCOME", c.Outcome)
	env = appendKV(env, "_DIAG_PIPELINE_STAGE", c.Stage)
	env = appendKV(env, "_DIAG_PIPELINE_TASK", c.Task)
	env = appendKV(env, "_DIAG_PIPELINE_MILESTONE", c.Milestone)
	env = appendKV(env, "_DIAG_EXIT_REASON", c.ExitReason)
	env = appendKV(env, "_DIAG_LAST_CLASSIFICATION", c.Classification)
	env = appendKV(env, "_DIAG_SCHEMA_VERSION", strconv.Itoa(c.SchemaVersion))
	env = appendKV(env, "_DIAG_PRIMARY_CATEGORY", c.PrimaryCategory)
	env = appendKV(env, "_DIAG_PRIMARY_SUBCATEGORY", c.PrimarySubcategory)
	env = appendKV(env, "_DIAG_PRIMARY_SIGNAL", c.PrimarySignal)
	env = appendKV(env, "_DIAG_PRIMARY_SOURCE", c.PrimarySource)
	env = appendKV(env, "_DIAG_SECONDARY_CATEGORY", c.SecondaryCategory)
	env = appendKV(env, "_DIAG_SECONDARY_SUBCATEGORY", c.SecondarySubcategory)
	env = appendKV(env, "_DIAG_SECONDARY_SIGNAL", c.SecondarySignal)
	env = appendKV(env, "_DIAG_SECONDARY_SOURCE", c.SecondarySource)
	env = appendKV(env, "_DIAG_REVIEW_CYCLES", strconv.Itoa(c.ReviewCycles))
	env = appendKV(env, "_DIAG_CAUSE_CHAIN", c.CauseChain)
	env = appendKV(env, "_DIAG_CAUSE_CHAIN_SHORT", c.CauseChainShort)
	env = appendKV(env, "_DIAG_TERMINAL_EVENT", c.TerminalEvent)
	env = appendKV(env, "_DIAG_ERROR_EVENTS", c.ErrorEvents)
	env = appendKV(env, "_DIAG_AGENT_LOG_TAILS", flattenLogTails(c.AgentLogTails))

	// Large field — tempfile fallback when over the limit.
	var tempFiles []string
	cleanup := func() {
		for _, p := range tempFiles {
			_ = os.Remove(p)
		}
	}
	causalEnv, tempPath, err := maybeOffloadLarge("_DIAG_CAUSAL_EVENTS", c.CausalEvents)
	if err != nil {
		cleanup()
		return nil, func() {}, err
	}
	if tempPath != "" {
		tempFiles = append(tempFiles, tempPath)
		env = appendKV(env, "_DIAG_CAUSAL_EVENTS_FILE", tempPath)
		env = appendKV(env, "_DIAG_CAUSAL_EVENTS", "")
	} else {
		env = appendKV(env, "_DIAG_CAUSAL_EVENTS", causalEnv)
	}

	return env, cleanup, nil
}

// maybeOffloadLarge returns (value, "", nil) when value fits under the
// limit, or ("", tempFilePath, nil) when it does not. Used to keep the
// per-process env-var budget bounded.
func maybeOffloadLarge(name, value string) (string, string, error) {
	if len(value) <= envVarRoundTripLimit {
		return value, "", nil
	}
	tmp, err := os.CreateTemp("", "tekhton-diag-"+sanitizeName(name)+"-*.txt")
	if err != nil {
		return "", "", err
	}
	defer tmp.Close()
	if _, err := tmp.WriteString(value); err != nil {
		_ = os.Remove(tmp.Name())
		return "", "", err
	}
	return "", tmp.Name(), nil
}

func sanitizeName(s string) string {
	s = strings.TrimPrefix(s, "_")
	return strings.ToLower(strings.ReplaceAll(s, "_", "-"))
}

func appendKV(env []string, key, val string) []string {
	return append(env, key+"="+val)
}

func flattenLogTails(m map[string]string) string {
	if len(m) == 0 {
		return ""
	}
	var b strings.Builder
	for name, tail := range m {
		b.WriteString("--- ")
		b.WriteString(name)
		b.WriteString(" (last 20 lines) ---\n")
		b.WriteString(tail)
		b.WriteString("\n")
	}
	return b.String()
}

// bashWrapperScript returns the bash one-liner the adapter exec's. It
// sources the required libraries, optionally loads the tempfile-backed
// causal events, invokes the rule, and prints the structured output.
func bashWrapperScript(ruleName string) string {
	return `set -uo pipefail
: "${TEKHTON_HOME:?missing}"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/state.sh"
source "${TEKHTON_HOME}/lib/causality.sh" 2>/dev/null || true
source "${TEKHTON_HOME}/lib/diagnose_helpers.sh"
source "${TEKHTON_HOME}/lib/diagnose_rules.sh"

# Large-value tempfile rehydration.
if [[ -n "${_DIAG_CAUSAL_EVENTS_FILE:-}" ]] && [[ -f "${_DIAG_CAUSAL_EVENTS_FILE}" ]]; then
    _DIAG_CAUSAL_EVENTS=$(cat -- "${_DIAG_CAUSAL_EVENTS_FILE}" 2>/dev/null || true)
fi

DIAG_CLASSIFICATION=""
DIAG_CONFIDENCE=""
DIAG_SUGGESTIONS=()

if ` + ruleName + ` 2>/dev/null; then
    printf 'DIAG_CLASSIFICATION=%s\n' "${DIAG_CLASSIFICATION}"
    printf 'DIAG_CONFIDENCE=%s\n' "${DIAG_CONFIDENCE}"
    printf 'DIAG_SUGGESTIONS_COUNT=%d\n' "${#DIAG_SUGGESTIONS[@]}"
    for s in "${DIAG_SUGGESTIONS[@]}"; do
        # Replace embedded newlines with a sentinel so the Go parser
        # can split by literal LF.
        printf 'DIAG_SUGGESTION=%s\n' "${s//$'\n'/\\n}"
    done
    exit 0
fi
exit 1
`
}

// parseRuleOutput decodes the structured KEY=VALUE block the bash wrapper
// prints. Returns a Diagnosis populated from the keys.
func parseRuleOutput(stdout, ruleName, fallbackStage string) Diagnosis {
	d := Diagnosis{RuleName: ruleName, Stage: fallbackStage}
	sc := bufio.NewScanner(strings.NewReader(stdout))
	// Allow long suggestion lines.
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		eq := strings.Index(line, "=")
		if eq < 0 {
			continue
		}
		key, val := line[:eq], line[eq+1:]
		switch key {
		case "DIAG_CLASSIFICATION":
			d.Classification = val
		case "DIAG_CONFIDENCE":
			d.Confidence = Confidence(val)
		case "DIAG_SUGGESTION":
			d.Suggestions = append(d.Suggestions, strings.ReplaceAll(val, `\n`, "\n"))
		}
	}
	return d
}

// AdapterBashWrapperPath is exported for the rule-output integration
// test to verify the bash wrapper file is reachable when callers
// override the script search path.
func AdapterBashWrapperPath(home string) string {
	return filepath.Join(home, "lib", "diagnose_rules.sh")
}
