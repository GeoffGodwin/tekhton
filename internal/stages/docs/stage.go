// Package docs is the Go-native docs-agent stage. m34.1 ports it from
// stages/docs.sh + lib/docs_agent.sh as the first child of the m34 stage-port
// arc; m35-m39 will follow the same pattern (skip-check helpers in skip.go,
// template variable prep in prepare.go, entry point in stage.go).
//
// The stage is best-effort: every code path returns verdict=skip (with an
// exit_reason identifying which gate fired) or verdict=pass when the agent
// completed. Verdict=fail is never returned — matches the bash semantics where
// every branch of run_stage_docs ends with `return 0`.
package docs

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/prompt"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/stages/staglog"
)

// stageProvider is the package-level provider seam. Production code sets it
// via SetProvider before running the pipeline; tests inject a fake.
var stageProvider provider.Provider

// SetProvider replaces the package-level provider. Returns the previous value
// so callers can defer-restore.
func SetProvider(p provider.Provider) provider.Provider {
	prev := stageProvider
	stageProvider = p
	return prev
}

// RunStage is the m34.1 entry point. Signature matches stagerunner.StageImpl
// so DefaultStageDefs[StageDocs] can register it directly. The docs stage
// never returns verdict=fail; on any internal error the result carries
// verdict=skip with an exit_reason that names the failing step.
func RunStage(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	cfg := loadConfig()
	log := staglog.New(req)
	log.Header("Docs")

	projectDir := resolveProjectDir(req)

	// Gate 1: master toggle off (production default).
	if !envBool("DOCS_AGENT_ENABLED", false) {
		log.Info("[docs] Docs agent disabled (DOCS_AGENT_ENABLED=false). Skipping.")
		return skipResult(req, "disabled"), nil
	}

	// Gate 2: explicit --skip-docs.
	if envBool("SKIP_DOCS", false) {
		log.Info("[docs] Docs stage skipped (--skip-docs). Skipping.")
		return skipResult(req, "skip-flag"), nil
	}

	// Gate 3: no public-surface change.
	rulesFile := envOr("PROJECT_RULES_FILE", "CLAUDE.md")
	if shouldSkip(projectDir, rulesFile, log) {
		return skipResult(req, "no-public-surface-change"), nil
	}

	// Render prompt.
	vars := prepareTemplateVars(projectDir, req)
	promptsDir := resolvePromptsDir(req)
	promptText, err := prompt.Render(promptsDir, "docs_agent", vars)
	if err != nil {
		log.Warn(fmt.Sprintf("[docs] render prompt: %v", err))
		return skipResult(req, "prompt-failed"), nil
	}

	model := envOr("DOCS_AGENT_MODEL", "claude-haiku-4-5-20251001")
	turns := envInt("DOCS_AGENT_MAX_TURNS", 10)
	tools := envOr("AGENT_TOOLS_CODER", "Read Write Edit Glob Grep Bash")

	log.Info(fmt.Sprintf("[docs] Invoking docs agent (model=%s, turns=%d)...", model, turns))

	agentRes, agentErr := cfg.Provider.RunAgent(ctx, &provider.Request{
		Prompt:       promptText,
		Label:        "Docs",
		Model:        model,
		MaxTurns:     turns,
		WorkingDir:   projectDir,
		AllowedTools: tools,
	})
	if agentErr != nil || agentRes == nil || agentRes.Outcome != provider.OutcomeSuccess {
		log.Warn("[docs] Docs agent run failed — continuing pipeline without docs updates.")
		return skipResult(req, "agent-failed"), nil
	}

	log.Info(fmt.Sprintf("[docs] Docs agent finished. Report: %s", vars["DOCS_AGENT_REPORT_FILE"]))
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictPass,
		ExitReason: "agent-completed",
		AgentCalls: 1,
	}, nil
}

func skipResult(req *proto.StageRequestV1, reason string) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictSkip,
		ExitReason: reason,
	}
}

func resolveProjectDir(req *proto.StageRequestV1) string {
	if req != nil && req.EnvOverrides != nil {
		if v, ok := req.EnvOverrides["PROJECT_DIR"]; ok && v != "" {
			return v
		}
	}
	if v := os.Getenv("PROJECT_DIR"); v != "" {
		return v
	}
	wd, _ := os.Getwd()
	return wd
}

func resolvePromptsDir(req *proto.StageRequestV1) string {
	if req != nil && req.EnvOverrides != nil {
		if v, ok := req.EnvOverrides["TEKHTON_HOME"]; ok && v != "" {
			return filepath.Join(v, "prompts")
		}
	}
	if v := os.Getenv("TEKHTON_HOME"); v != "" {
		return filepath.Join(v, "prompts")
	}
	// Last-ditch fallback — assume the binary runs from the repo root.
	return "prompts"
}

func envBool(key string, fallback bool) bool {
	v, ok := os.LookupEnv(key)
	if !ok {
		return fallback
	}
	switch v {
	case "1", "true", "TRUE", "True", "yes", "YES":
		return true
	case "0", "false", "FALSE", "False", "no", "NO", "":
		return false
	}
	return fallback
}

func envInt(key string, fallback int) int {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return fallback
	}
	n := 0
	for _, r := range v {
		if r < '0' || r > '9' {
			return fallback
		}
		n = n*10 + int(r-'0')
	}
	if n <= 0 {
		return fallback
	}
	return n
}
