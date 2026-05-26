package failure_context

import (
	"bytes"
	"strings"
	"testing"
)

func TestSetPrimaryAndReset(t *testing.T) {
	c := New()
	c.SetPrimary("config", "ui_test_config", "interactive_report", "preflight")
	if c.Primary.Category != "config" {
		t.Errorf("Category = %q, want config", c.Primary.Category)
	}
	if c.Primary.Source != "preflight" {
		t.Errorf("Source = %q, want preflight", c.Primary.Source)
	}
	if c.Primary.IsEmpty() {
		t.Error("Primary should not be empty after SetPrimary")
	}
	c.Reset()
	if !c.Primary.IsEmpty() || !c.Secondary.IsEmpty() {
		t.Error("Reset did not clear both slots")
	}
}

func TestSetSecondary(t *testing.T) {
	c := New()
	c.SetSecondary("runtime", "max_turns_exhausted", "", "build_fix")
	if c.Secondary.Category != "runtime" || c.Secondary.Source != "build_fix" {
		t.Errorf("Secondary not populated correctly: %+v", c.Secondary)
	}
}

func TestFormatSummary_Empty(t *testing.T) {
	c := New()
	if got := c.FormatSummary(); got != "" {
		t.Errorf("empty context summary = %q, want empty string", got)
	}
}

func TestFormatSummary_PrimaryOnly(t *testing.T) {
	c := New()
	c.SetPrimary("config", "ui_test_config", "interactive_report", "preflight")
	got := c.FormatSummary()
	want := "Primary cause: config/ui_test_config (interactive_report)"
	if got != want {
		t.Errorf("FormatSummary = %q, want %q", got, want)
	}
}

func TestFormatSummary_SecondaryOnly(t *testing.T) {
	c := New()
	c.SetSecondary("runtime", "max_turns_exhausted", "", "build_fix")
	got := c.FormatSummary()
	want := "Secondary cause: runtime/max_turns_exhausted"
	if got != want {
		t.Errorf("FormatSummary = %q, want %q", got, want)
	}
}

func TestFormatSummary_Both(t *testing.T) {
	c := New()
	c.SetPrimary("config", "ui_test_config", "interactive_report", "preflight")
	c.SetSecondary("runtime", "max_turns_exhausted", "", "build_fix")
	got := c.FormatSummary()
	lines := strings.Split(got, "\n")
	if len(lines) != 2 {
		t.Fatalf("FormatSummary lines = %d, want 2 (got %q)", len(lines), got)
	}
	if !strings.HasPrefix(lines[0], "Primary") {
		t.Errorf("first line = %q, want Primary first", lines[0])
	}
	if !strings.HasPrefix(lines[1], "Secondary") {
		t.Errorf("second line = %q, want Secondary second", lines[1])
	}
}

func TestFormatSummary_QuestionMarkDefaults(t *testing.T) {
	c := New()
	// Signal-only — category + subcategory should fall back to "?"
	c.SetPrimary("", "", "some_signal", "stage_x")
	got := c.FormatSummary()
	want := "Primary cause: ?/? (some_signal)"
	if got != want {
		t.Errorf("FormatSummary = %q, want %q", got, want)
	}
}

func TestEmitJSON_Empty(t *testing.T) {
	c := New()
	var buf bytes.Buffer
	if err := c.EmitJSON(&buf); err != nil {
		t.Fatal(err)
	}
	if buf.Len() != 0 {
		t.Errorf("empty context produced output: %q", buf.String())
	}
}

func TestEmitJSON_PrimaryOnly(t *testing.T) {
	c := New()
	c.SetPrimary("config", "ui_test_config", "interactive_report", "preflight")
	var buf bytes.Buffer
	if err := c.EmitJSON(&buf); err != nil {
		t.Fatal(err)
	}
	got := buf.String()
	// The bash contract: each emitted object is followed by ",\n".
	want := `  "primary_cause": {
    "category": "config",
    "subcategory": "ui_test_config",
    "signal": "interactive_report",
    "source": "preflight"
  },
`
	if got != want {
		t.Errorf("EmitJSON mismatch.\nwant:\n%s\ngot:\n%s", want, got)
	}
}

func TestEmitJSON_Both(t *testing.T) {
	c := New()
	c.SetPrimary("config", "ui_test_config", "interactive_report", "preflight")
	c.SetSecondary("runtime", "max_turns_exhausted", "", "build_fix")
	var buf bytes.Buffer
	if err := c.EmitJSONIndent(&buf, "  "); err != nil {
		t.Fatal(err)
	}
	got := buf.String()
	if !strings.Contains(got, `"primary_cause": {`) {
		t.Error("missing primary_cause key")
	}
	if !strings.Contains(got, `"secondary_cause": {`) {
		t.Error("missing secondary_cause key")
	}
	// Each block should be followed by ",\n" so the writer can chain more keys.
	if !strings.HasSuffix(got, ",\n") {
		t.Errorf("output should end with ',\\n', got %q", got)
	}
}

func TestEmitJSON_EscapesQuotesAndBackslashes(t *testing.T) {
	c := New()
	c.SetPrimary(`raw"value`, `with\backslash`, "", "")
	var buf bytes.Buffer
	if err := c.EmitJSON(&buf); err != nil {
		t.Fatal(err)
	}
	got := buf.String()
	// The quote in raw"value should become \" in the output.
	if !strings.Contains(got, `raw\"value`) {
		t.Errorf("quote not escaped: %q", got)
	}
	// The backslash in with\backslash should become \\.
	if !strings.Contains(got, `with\\backslash`) {
		t.Errorf("backslash not escaped: %q", got)
	}
}

func TestAliasCategory(t *testing.T) {
	c := New()
	// Secondary populated — wins.
	c.SetSecondary("runtime", "max_turns_exhausted", "", "build_fix")
	if got := c.AliasCategory("agent_fallback"); got != "runtime" {
		t.Errorf("AliasCategory = %q, want runtime (secondary wins)", got)
	}
	// Secondary cleared — fallback to agent value.
	c.Reset()
	if got := c.AliasCategory("agent_fallback"); got != "agent_fallback" {
		t.Errorf("AliasCategory = %q, want agent_fallback (fallback)", got)
	}
	// Both empty.
	if got := c.AliasCategory(""); got != "" {
		t.Errorf("AliasCategory = %q, want empty", got)
	}
}

func TestAliasSubcategory(t *testing.T) {
	c := New()
	c.SetSecondary("", "max_turns_exhausted", "", "")
	if got := c.AliasSubcategory("agent_sub"); got != "max_turns_exhausted" {
		t.Errorf("AliasSubcategory = %q, want max_turns_exhausted", got)
	}
	c.Reset()
	if got := c.AliasSubcategory("agent_sub"); got != "agent_sub" {
		t.Errorf("AliasSubcategory = %q, want agent_sub", got)
	}
}

func TestCause_IsEmpty(t *testing.T) {
	if !(Cause{}).IsEmpty() {
		t.Error("zero-value Cause should be empty")
	}
	if (Cause{Category: "x"}).IsEmpty() {
		t.Error("Category=x Cause should not be empty")
	}
	if (Cause{Source: "preflight"}).IsEmpty() {
		t.Error("Source-only Cause should not be empty")
	}
}
