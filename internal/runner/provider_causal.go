package runner

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/causal"
)

// chainCausalEmitter builds the CausalEmitter attached to chains by
// ResolveProvider. It writes provider_fallthrough events to the project's
// causal log, mirroring cmd/tekhton's completion-gate emitter. Returns nil
// (a valid no-op for Chain.Causal) when causal logging is disabled, so a
// chain in a test or a logging-off run still works.
func chainCausalEmitter() CausalEmitter {
	if v := os.Getenv("CAUSAL_LOG_ENABLED"); v == "false" || v == "0" {
		return nil
	}
	logPath := os.Getenv("CAUSAL_LOG_FILE")
	if logPath == "" {
		logPath = filepath.Join(".claude", "logs", "CAUSAL_LOG.jsonl")
	}
	if pd := os.Getenv("PROJECT_DIR"); pd != "" && !filepath.IsAbs(logPath) {
		logPath = filepath.Join(pd, logPath)
	}
	maxEvents := 2000
	if v := os.Getenv("CAUSAL_LOG_MAX_EVENTS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			maxEvents = n
		}
	}
	runID := os.Getenv("RUN_ID")
	if runID == "" {
		runID = os.Getenv("_CURRENT_RUN_ID")
	}
	milestone := os.Getenv("_CURRENT_MILESTONE")

	return CausalFunc(func(eventType string, fields map[string]string) {
		l, err := causal.Open(logPath, maxEvents, runID)
		if err != nil {
			return
		}
		defer func() { _ = l.Close() }()
		_, _ = l.Emit(causal.EmitInput{
			Stage:     "provider_chain",
			Type:      eventType,
			Detail:    formatChainDetail(fields),
			Milestone: milestone,
		})
	})
}

// formatChainDetail renders the field map as a deterministic "k=v k=v" string.
// A fixed leading order keeps the common fallthrough fields stable; any extra
// keys follow in sorted order so nothing is silently dropped.
func formatChainDetail(fields map[string]string) string {
	order := []string{"from", "from_tier", "to", "to_tier", "error_category", "error_subcategory"}
	seen := map[string]bool{}
	var b strings.Builder
	add := func(k string) {
		v, ok := fields[k]
		if !ok || v == "" || seen[k] {
			return
		}
		seen[k] = true
		if b.Len() > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(k)
		b.WriteByte('=')
		b.WriteString(v)
	}
	for _, k := range order {
		add(k)
	}
	extra := make([]string, 0, len(fields))
	for k := range fields {
		if !seen[k] {
			extra = append(extra, k)
		}
	}
	sort.Strings(extra)
	for _, k := range extra {
		add(k)
	}
	return b.String()
}
