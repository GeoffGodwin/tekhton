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

// EmitPipelineConf writes a comprehensive, self-documenting pipeline.conf
// reference. Every known key appears as a commented `# KEY="value"` line
// with its default value, so an operator can find any setting by reading
// the file once and uncomment the lines they want to override.
//
// This is the canonical output for templates/pipeline.conf.example and for
// `tekhton --init`'s "full reference" footer. The user-curated section
// (PROJECT_NAME, TEST_CMD, ANALYZE_CMD, etc.) lives above the reference
// block in the init-generated file; this helper produces the reference
// block alone.
//
// Format conventions:
//   - One blank line precedes each key (visual separator).
//   - Empty defaults render as `# KEY=""` so the variable form is still
//     visible — operator can drop the leading `#` and fill in a value
//     without re-deriving the syntax.
//   - Values use double-quote rendering since pipeline.conf is bash-sourced
//     and operators typically write `KEY="value"`. Embedded double quotes
//     get backslash-escaped to keep the file parseable.
//   - Keys are emitted in lexicographic order — matches EmitShell and is
//     reproducible across runs.
func (c *Config) EmitPipelineConf(w io.Writer) error {
	header := `# =============================================================================
# Tekhton pipeline.conf — Full Configuration Reference
#
# Every Tekhton-recognized variable is listed below as a commented line with
# its default value. Uncomment any line to override the default for this
# project. Custom values you add are preserved by ` + "`tekhton --reinit`" + `.
#
# Format: KEY="value" (no spaces around =, quote strings, no trailing comments
# on the same line as a KEY=).
#
# Variables are grouped into logical sections. Within each section, keys are
# alphabetical for findability. The init generator produces a curated header
# above this reference with the variables most projects need to set first
# (PROJECT_NAME, TEST_CMD, ANALYZE_CMD, ARCHITECTURE_FILE).
# =============================================================================
`
	if _, err := fmt.Fprint(w, header); err != nil {
		return err
	}

	// Bucket keys by section. Sections preserve their declared order;
	// keys within a section are alphabetical.
	buckets := make(map[string][]string, len(pipelineConfSections)+1)
	for k := range c.Values {
		buckets[SectionFor(k)] = append(buckets[SectionFor(k)], k)
	}
	for _, keys := range buckets {
		sort.Strings(keys)
	}

	for _, section := range SectionsInOrder() {
		keys, ok := buckets[section.Name]
		if !ok || len(keys) == 0 {
			continue
		}
		if err := writeSectionHeader(w, section.Name, section.Description, len(keys)); err != nil {
			return err
		}
		for _, k := range keys {
			v := c.Values[k]
			// Escape backslash first, then double quote, so the result is
			// safe to drop into bash's `KEY="value"` form unchanged.
			escaped := strings.ReplaceAll(v, `\`, `\\`)
			escaped = strings.ReplaceAll(escaped, `"`, `\"`)
			if _, err := fmt.Fprintf(w, "\n# %s=\"%s\"\n", k, escaped); err != nil {
				return err
			}
		}
	}
	return nil
}

// writeSectionHeader writes a banner-style section header to w with a
// short rule, the section name, a one-line description, and the count
// of variables in the section.
func writeSectionHeader(w io.Writer, name, description string, count int) string2err {
	banner := "# " + strings.Repeat("=", 77) + "\n"
	if _, err := fmt.Fprint(w, "\n"+banner); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "# %s  (%d %s)\n", name, count, plural(count, "variable", "variables")); err != nil {
		return err
	}
	if description != "" {
		if _, err := fmt.Fprintf(w, "# %s\n", description); err != nil {
			return err
		}
	}
	if _, err := fmt.Fprint(w, banner); err != nil {
		return err
	}
	return nil
}

// string2err is a tiny alias to keep writeSectionHeader's return type
// readable; Go has no exception type so we propagate io.Writer errors.
type string2err = error

// plural returns the singular form when n == 1, otherwise the plural.
func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
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
