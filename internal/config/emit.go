package config

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EmitShell writes a sourceable bash environment to w. Each known key is
// emitted as `export KEY='value'` with single-quote escaping for safety.
// Output is deterministic — keys are emitted in lexicographic order so
// `tekhton config load --emit shell | source` is reproducible across runs.
//
// The bash shim sources the output via `eval` after a paranoia check so a
// rogue line in the emitted stream cannot inject unexpected behaviour.
func (c *Config) EmitShell(w io.Writer) error {
	keys := make([]string, 0, len(c.Values))
	for k := range c.Values {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if _, err := fmt.Fprintf(w, "export %s=%s\n", k, shellQuote(c.Values[k])); err != nil {
			return err
		}
	}
	return nil
}

// EmitJSON writes the config as a JSON object. Includes the resolved values,
// the set of operator-authored keys (`keys_set`), and CI metadata. Used by
// `tekhton config show --json` for tooling and tests that need structured
// access to the loaded config.
func (c *Config) EmitJSON(w io.Writer, indent bool) error {
	keysSet := make([]string, 0, len(c.KeysSet))
	for k := range c.KeysSet {
		keysSet = append(keysSet, k)
	}
	sort.Strings(keysSet)

	// The envelope shape and version tag live in internal/proto so any
	// cross-language consumer (current or future) imports a single typed
	// view. encoding/json sorts map keys deterministically, so emit order
	// is stable across runs.
	payload := proto.ConfigV1{
		Path:        c.Path,
		ProjectDir:  c.ProjectDir,
		Values:      c.Values,
		KeysSet:     keysSet,
		Warnings:    c.Warnings,
		Errors:      c.Errors,
		CIDetected:  c.CIDetected,
		CIPlatform:  c.CIPlatform,
		EnvelopeVer: proto.ConfigProtoV1,
	}

	enc := json.NewEncoder(w)
	if indent {
		enc.SetIndent("", "  ")
	}
	enc.SetEscapeHTML(false)
	return enc.Encode(payload)
}

// shellQuote returns s wrapped in single quotes with embedded single quotes
// escaped via the standard close-quote, escaped-quote, open-quote idiom.
// Suitable for sourcing inside bash.
func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}
