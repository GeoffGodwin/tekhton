// Package staglog is the thin colored-output wrapper Go-native stages use to
// match the bash log/warn/success/header API that lib/common.sh provided to
// stages/*.sh before the m34 stage-port arc.
//
// The package is intentionally minimal in m34.1 — only the four operations
// every ported stage needs (Header, Info, Warn, Success). Future stage
// milestones extend the surface when the need is concrete; adding level
// filtering, error sinks, or structured fields belongs in the milestone that
// first needs them.
package staglog

import (
	"fmt"
	"io"
	"os"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// Logger is the entry-point interface a stage holds. Header is intended to be
// called once at stage entry; Info / Warn / Success may be called any number
// of times.
type Logger interface {
	Header(stage string)
	Info(msg string)
	Warn(msg string)
	Success(msg string)
}

// Pipeline-position env keys. Pre-port, stages/docs.sh read these directly
// via shell expansion; the Go side resolves them once at New() time so the
// renderer is testable without an environment.
const (
	envStagePos   = "PIPELINE_STAGE_POS"
	envStageCount = "PIPELINE_STAGE_COUNT"
)

// New returns a stderr-backed Logger sized from the calling stage's request.
// The pipeline position falls back to (1/1) when the orchestrator hasn't
// populated PIPELINE_STAGE_POS / PIPELINE_STAGE_COUNT — keeps unit tests
// renderable without an environment.
func New(req *proto.StageRequestV1) Logger {
	pos := envOrInt(envStagePos, 1)
	count := envOrInt(envStageCount, 1)
	if req != nil && req.EnvOverrides != nil {
		if v, ok := req.EnvOverrides[envStagePos]; ok {
			pos = atoiOr(v, pos)
		}
		if v, ok := req.EnvOverrides[envStageCount]; ok {
			count = atoiOr(v, count)
		}
	}
	return &stderrLogger{w: os.Stderr, pos: pos, count: count}
}

// NewWithWriter is the test-friendly constructor: callers pass an io.Writer
// and explicit position so output can be captured deterministically without
// touching os.Stderr or process env.
func NewWithWriter(w io.Writer, pos, count int) Logger {
	if w == nil {
		w = io.Discard
	}
	return &stderrLogger{w: w, pos: pos, count: count}
}

type stderrLogger struct {
	w     io.Writer
	pos   int
	count int
}

// Header prints the "[pos/count] StageName" banner. The format matches the
// acceptance regex `^\[\d+/\d+\] [A-Z][a-zA-Z]+$` from m34.1 — callers should
// pass a TitleCase stage name (e.g. "Docs"), not the lowercase stage constant.
func (l *stderrLogger) Header(stage string) {
	fmt.Fprintf(l.w, "[%d/%d] %s\n", l.pos, l.count, stage)
}

func (l *stderrLogger) Info(msg string)    { fmt.Fprintln(l.w, msg) }
func (l *stderrLogger) Warn(msg string)    { fmt.Fprintln(l.w, "WARN: "+msg) }
func (l *stderrLogger) Success(msg string) { fmt.Fprintln(l.w, "OK: "+msg) }

func envOrInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	return atoiOr(v, fallback)
}

// atoiOr parses v as a positive decimal integer; on any failure or non-positive
// result it returns fallback. Pipeline position / count are always ≥ 1.
func atoiOr(v string, fallback int) int {
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
