package errors

import "strings"

// SuggestRecovery ports lib/errors_helpers.sh::suggest_recovery. Returns a
// single-sentence recovery hint for (category, subcategory). The optional
// context fills the {state-file} placeholder used by PIPELINE/state_corrupt;
// pass "" when not applicable.
func SuggestRecovery(category, subcategory, context string) string {
	key := category + "/" + subcategory
	switch key {
	case "UPSTREAM/api_500":
		return "Anthropic API server error. Wait a few minutes and re-run the same command."
	case "UPSTREAM/api_rate_limit":
		return "API rate limit hit. Wait 60 seconds and re-run. Consider reducing concurrent API calls."
	case "UPSTREAM/api_overloaded":
		return "Anthropic API is overloaded. Wait a few minutes and re-run the same command."
	case "UPSTREAM/api_auth":
		return "API authentication failed. Check your ANTHROPIC_API_KEY and re-authenticate with 'claude auth'."
	case "UPSTREAM/api_timeout":
		return "API connection timed out. Check your network connection and re-run."
	case "UPSTREAM/api_unknown":
		return "Unrecognized API error. Check Anthropic status page and re-run."
	case "ENVIRONMENT/disk_full":
		return "Disk is full. Free up space and re-run."
	case "ENVIRONMENT/network":
		return "Network connectivity issue. Check your internet connection and DNS settings."
	case "ENVIRONMENT/missing_dep":
		return "A required command is not installed. Install the missing dependency and re-run."
	case "ENVIRONMENT/permissions":
		return "Permission denied. Check file/directory permissions and re-run."
	case "ENVIRONMENT/oom":
		return "Process was killed (likely OOM). Close other applications to free memory, or increase available RAM."
	case "ENVIRONMENT/env_unknown":
		return "Unexpected environment error. Check system logs for details."
	case "ENVIRONMENT/env_setup":
		return "Missing tool or binary. Install the required dependency (check ${BUILD_ERRORS_FILE} for the exact command)."
	case "ENVIRONMENT/service_dep":
		return "A required service is not running (database, cache, or queue). Start it and re-run."
	case "ENVIRONMENT/toolchain":
		return "Build toolchain issue (stale deps, missing codegen). Run the suggested install/generate command."
	case "ENVIRONMENT/resource":
		return "Machine resource constraint (port in use, OOM, disk full, permissions). Resolve the resource conflict and re-run."
	case "ENVIRONMENT/test_infra":
		return "Test infrastructure issue (stale snapshots, missing fixtures, timeout). Update test infrastructure and re-run."
	case "AGENT_SCOPE/null_run":
		return "Agent died before doing meaningful work. The prompt may be too large or the task too ambiguous. Try splitting the milestone or simplifying the task."
	case "AGENT_SCOPE/max_turns":
		return "Agent exhausted its turn budget. The task may be too large for the configured turn limit. Try splitting the milestone or increasing *_MAX_TURNS in pipeline.conf."
	case "AGENT_SCOPE/activity_timeout":
		return "Agent went silent after producing some output. Increase AGENT_ACTIVITY_TIMEOUT in pipeline.conf, or check if the agent is stuck in a tool-use retry loop."
	case "AGENT_SCOPE/null_activity_timeout":
		return "Agent never produced any output before activity timeout — almost always upstream. Check: (1) Anthropic API quota for the model in use, (2) 'claude' CLI auth state ('claude auth status'), (3) network reachability to api.anthropic.com. Re-running immediately will hit the same wall — wait for quota refresh or fix auth first."
	case "AGENT_SCOPE/no_summary":
		return "Agent completed but didn't produce expected output files. Re-run to retry."
	case "AGENT_SCOPE/scope_unknown":
		return "Agent completed without a clear outcome. Check the run log for details."
	case "PIPELINE/state_corrupt":
		ctx := context
		if ctx == "" {
			ctx = ".claude/PIPELINE_STATE.md"
		}
		return "Pipeline state file is corrupt. Delete " + ctx + " and re-run from scratch."
	case "PIPELINE/config_error":
		return "Pipeline configuration error. Fix pipeline.conf and re-run."
	case "PIPELINE/missing_file":
		return "A required artifact file is missing. Re-run the pipeline from an earlier stage."
	case "PIPELINE/template_error":
		return "Prompt template failed to render. Check that the template exists in prompts/ and all required variables are set."
	case "PIPELINE/internal":
		return "Internal pipeline error. Check the run log for details. If this persists, file a bug."
	}
	if strings.Contains(key, "/") {
		return "Unknown error. Check the run log for details."
	}
	return "Unknown error. Check the run log for details."
}
