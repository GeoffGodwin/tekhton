package review

import (
	"os"
	"strconv"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// envBool mirrors the security/docs helpers.
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

// envInt parses a non-negative integer env value. Zero is rejected as "unset"
// and falls back to the default.
func envInt(key string, fallback int) int {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
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

// envOrFromReq prefers the request EnvOverrides over process env over fallback.
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
