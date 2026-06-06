package intake

import (
	"os"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// envBool mirrors the docs/cleanup/security stage helpers verbatim.
// NOTE: process-env-only. For env keys delivered via req.EnvOverrides
// (in-process GoImpl path), use envBoolFromReq instead.
func envBool(key string, fallback bool) bool {
	v, ok := os.LookupEnv(key)
	if !ok {
		return fallback
	}
	return parseBool(v, fallback)
}

// envInt parses a non-negative integer env value. Zero / non-numeric falls
// back to fallback so the calling code never sees an unset/invalid 0.
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

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envOrFromReq prefers req.EnvOverrides[key] when non-empty, then
// process env, then fallback. Mirrors the security/docs helpers.
func envOrFromReq(req *proto.StageRequestV1, key, fallback string) string {
	if req != nil && req.EnvOverrides != nil {
		if v, ok := req.EnvOverrides[key]; ok && v != "" {
			return v
		}
	}
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envBoolFromReq is the bool counterpart of envOrFromReq. Required because
// in-process GoImpl calls receive the composed env via req.EnvOverrides —
// NOT via process env. envBool alone (process-env-only) reads "" and
// returns the fallback, which silently breaks MILESTONE_MODE-gated
// behavior. Specifically: with MILESTONE_MODE only in EnvOverrides and
// not in os.Environ, intake.MilestoneContent short-circuits at
// helpers.go:165 (`if !milestoneMode || currentMs == ""`) and returns
// the bare task title instead of loading the milestone file. That is
// the m37.1 NEEDS_CLARITY false-positive root cause — the previous
// "wire MilestoneFileResolver" fix was a no-op because the resolver
// is never consulted on this short-circuited path.
func envBoolFromReq(req *proto.StageRequestV1, key string, fallback bool) bool {
	if req != nil && req.EnvOverrides != nil {
		if v, ok := req.EnvOverrides[key]; ok && v != "" {
			return parseBool(v, fallback)
		}
	}
	if v, ok := os.LookupEnv(key); ok {
		return parseBool(v, fallback)
	}
	return fallback
}

func parseBool(v string, fallback bool) bool {
	switch v {
	case "1", "true", "TRUE", "True", "yes", "YES":
		return true
	case "0", "false", "FALSE", "False", "no", "NO", "":
		return false
	}
	return fallback
}
