package security

import (
	"os"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// envBool mirrors the docs/cleanup helpers verbatim.
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

// envInt parses a non-negative integer env value. Zero is rejected because
// every consumer here treats it as "unset" and falls back to the default.
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
