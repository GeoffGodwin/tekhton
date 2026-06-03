package cleanup

import (
	"os"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// envBool, envInt, envOr, envOrFromReq mirror the docs-stage env helpers
// verbatim. m34.2 keeps a local copy rather than promoting them to
// staglog because the helper API is not yet stable enough to share —
// the m34.2 dogfood retro flags this as a candidate for consolidation
// when m35 adopts the pattern.

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

// envInt parses a non-negative integer env value. Unlike the docs-stage
// helper (which rejects zero because max-turns must be positive), this
// allows zero — CLEANUP_TRIGGER_THRESHOLD=0 and CLEANUP_BATCH_SIZE=0
// are legitimate "no debouncing" configurations.
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
	return n
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

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
