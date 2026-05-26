// Package failure_context is the m25 Go port of lib/failure_context.sh —
// the primary/secondary failure-cause slot helpers that the diagnose
// writer, orchestrate classifier, and finalize hooks all share.
//
// Two slots:
//
//   - Primary cause:   the upstream cause a stage knows precisely
//     (e.g. UI gate detecting an interactive reporter config).
//   - Secondary cause: the downstream effect a later stage observes
//     (e.g. max_turns timeout inside the build-fix loop).
//
// Each slot carries four fields — Category / Subcategory / Signal /
// Source — and is populated by stages via SetPrimary / SetSecondary.
// The diagnose writer consumes the JSON form via EmitJSON; the notes
// summary path consumes FormatSummary.
//
// The package mirrors the bash file line-by-line. Function bodies are
// pure — they touch nothing outside the receiver — so the orchestrator
// can keep a single *Context per run and pass it through without
// shelling to bash.
package failure_context

import (
	"fmt"
	"io"
	"strings"
)

// Cause is one slot of cause context. Empty fields are allowed; a
// fully-empty Cause is the "unset" state.
type Cause struct {
	Category    string
	Subcategory string
	Signal      string
	Source      string
}

// IsEmpty reports whether every field of the Cause is empty. Used by
// the writer to decide whether to emit the JSON object at all.
func (c Cause) IsEmpty() bool {
	return c.Category == "" && c.Subcategory == "" && c.Signal == "" && c.Source == ""
}

// Context holds both cause slots. The zero value is the "no causes
// recorded" state; callers should always go through New for clarity.
type Context struct {
	Primary   Cause
	Secondary Cause
}

// New returns a Context with both slots zeroed.
func New() *Context {
	return &Context{}
}

// SetPrimary populates the four primary-slot fields. Mirrors the bash
// set_primary_cause four-arg signature.
func (c *Context) SetPrimary(category, subcategory, signal, source string) {
	c.Primary.Category = category
	c.Primary.Subcategory = subcategory
	c.Primary.Signal = signal
	c.Primary.Source = source
}

// SetSecondary populates the four secondary-slot fields. Mirrors the
// bash set_secondary_cause four-arg signature.
func (c *Context) SetSecondary(category, subcategory, signal, source string) {
	c.Secondary.Category = category
	c.Secondary.Subcategory = subcategory
	c.Secondary.Signal = signal
	c.Secondary.Source = source
}

// Reset zeroes both slots. Called at run start, between auto-advance
// iterations, and after a successful finalize so subsequent same-shell
// invocations do not inherit stale cause state.
func (c *Context) Reset() {
	c.Primary = Cause{}
	c.Secondary = Cause{}
}

// FormatSummary produces the 0/1/2-line plain-text summary used by the
// notes block and TUI status writer. Lines are joined by "\n"; no
// trailing newline. Returns the empty string when both slots are unset.
func (c *Context) FormatSummary() string {
	var lines []string
	if !c.Primary.IsEmpty() {
		lines = append(lines, formatCauseLine("Primary cause", c.Primary))
	}
	if !c.Secondary.IsEmpty() {
		lines = append(lines, formatCauseLine("Secondary cause", c.Secondary))
	}
	return strings.Join(lines, "\n")
}

// formatCauseLine renders one cause as "Label: cat/sub" (or "...
// (signal)" when signal is set). Missing category or subcategory
// fall back to "?", mirroring the bash defensive default.
func formatCauseLine(label string, c Cause) string {
	cat := c.Category
	if cat == "" {
		cat = "?"
	}
	sub := c.Subcategory
	if sub == "" {
		sub = "?"
	}
	if c.Signal != "" {
		return fmt.Sprintf("%s: %s/%s (%s)", label, cat, sub, c.Signal)
	}
	return fmt.Sprintf("%s: %s/%s", label, cat, sub)
}

// EmitJSON writes the pretty-printed JSON cause-object pair to w. The
// output mirrors the bash emit_cause_objects_json contract used by the
// diagnose writer: each emitted object is followed by ",\n" so the
// writer can append more keys after them. When both slots are empty,
// nothing is written.
//
// Pretty-print contract (non-negotiable — downstream parsers grep -oP
// line by line, never with jq):
//
//   - One inner key per line, terminated by `}` on its own line.
//   - Closing brace gets a trailing comma when more keys follow at the
//     parent level.
//   - Default indent is two spaces (writer's top-level indent).
func (c *Context) EmitJSON(w io.Writer) error {
	return c.EmitJSONIndent(w, "  ")
}

// EmitJSONIndent is EmitJSON with an explicit indent string.
func (c *Context) EmitJSONIndent(w io.Writer, indent string) error {
	if !c.Primary.IsEmpty() {
		if err := emitCauseObject(w, indent, "primary_cause", c.Primary); err != nil {
			return err
		}
		if _, err := fmt.Fprint(w, ",\n"); err != nil {
			return err
		}
	}
	if !c.Secondary.IsEmpty() {
		if err := emitCauseObject(w, indent, "secondary_cause", c.Secondary); err != nil {
			return err
		}
		if _, err := fmt.Fprint(w, ",\n"); err != nil {
			return err
		}
	}
	return nil
}

// emitCauseObject writes one nested cause object preceded by the
// indented key. Mirrors the bash _fc_emit_cause_object helper exactly:
// values are pre-escaped via jsonEscape, then dropped into a "%s"
// template so the surrounding quotes are literal JSON, not Go-format
// quotes (which would double-escape).
func emitCauseObject(w io.Writer, indent, key string, c Cause) error {
	inner := indent + "  "
	if _, err := fmt.Fprintf(w, "%s\"%s\": {\n", indent, key); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "%s\"category\": \"%s\",\n", inner, jsonEscape(c.Category)); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "%s\"subcategory\": \"%s\",\n", inner, jsonEscape(c.Subcategory)); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "%s\"signal\": \"%s\",\n", inner, jsonEscape(c.Signal)); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "%s\"source\": \"%s\"\n", inner, jsonEscape(c.Source)); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "%s}", indent); err != nil {
		return err
	}
	return nil
}

// jsonEscape applies the minimal escape the bash helper used —
// backslash and double-quote only. Slot values are simple ASCII
// tokens in practice, but defensive escaping survives any future
// vocabulary expansion.
func jsonEscape(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return s
}

// AliasCategory implements the bash resolve_alias_category precedence
// chain: when secondary slot is populated, use its Category; otherwise
// fall back to the supplied agentCategory (the bash AGENT_ERROR_CATEGORY
// fallback). Returns the empty string when neither is set.
func (c *Context) AliasCategory(agentCategory string) string {
	if c.Secondary.Category != "" {
		return c.Secondary.Category
	}
	return agentCategory
}

// AliasSubcategory mirrors AliasCategory for subcategories.
func (c *Context) AliasSubcategory(agentSubcategory string) string {
	if c.Secondary.Subcategory != "" {
		return c.Secondary.Subcategory
	}
	return agentSubcategory
}
