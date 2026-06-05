package intake

import (
	"os"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// envBool mirrors the docs/cleanup/security stage helpers verbatim.
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
