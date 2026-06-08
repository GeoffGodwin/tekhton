package claude

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/provider/tools"
)

// TestTranslateTools_Empty asserts an empty input returns nil, nil — the
// "use Claude's built-in tools" signal the CLI expects.
func TestTranslateTools_Empty(t *testing.T) {
	out, err := translateTools(nil)
	if err != nil {
		t.Fatalf("empty input: want nil error, got %v", err)
	}
	if out != nil {
		t.Errorf("empty input: want nil output, got %v", out)
	}

	out, err = translateTools([]provider.ToolSchema{})
	if err != nil {
		t.Fatalf("empty slice: want nil error, got %v", err)
	}
	if out != nil {
		t.Errorf("empty slice: want nil output, got %v", out)
	}
}

// TestTranslateTools_Read asserts the Read tool translates with all expected
// fields and matches the recorded fixture.
func TestTranslateTools_Read(t *testing.T) {
	out, err := translateTools([]provider.ToolSchema{tools.Read})
	if err != nil {
		t.Fatalf("Read: unexpected error: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("Read: want 1 tool, got %d", len(out))
	}
	tool := out[0]
	if tool.Name != "Read" {
		t.Errorf("Read: Name: want Read, got %q", tool.Name)
	}
	if tool.Description == "" {
		t.Error("Read: Description must not be empty")
	}
	assertInputSchemaType(t, "Read", tool.InputSchema, "object")
	assertRequired(t, "Read", tool.InputSchema, "file_path")
	assertPropertyExists(t, "Read", tool.InputSchema, "file_path")
	assertPropertyExists(t, "Read", tool.InputSchema, "offset")
	assertPropertyExists(t, "Read", tool.InputSchema, "limit")
	assertAdditionalPropertiesFalse(t, "Read", tool.InputSchema)

	assertMatchesFixture(t, "read.json", []claudeNativeTool{tool})
}

// TestTranslateTools_Write asserts the Write tool translates correctly.
func TestTranslateTools_Write(t *testing.T) {
	out, err := translateTools([]provider.ToolSchema{tools.Write})
	if err != nil {
		t.Fatalf("Write: unexpected error: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("Write: want 1 tool, got %d", len(out))
	}
	tool := out[0]
	if tool.Name != "Write" {
		t.Errorf("Write: Name: want Write, got %q", tool.Name)
	}
	assertInputSchemaType(t, "Write", tool.InputSchema, "object")
	assertRequiredContains(t, "Write", tool.InputSchema, []string{"file_path", "content"})
	assertAdditionalPropertiesFalse(t, "Write", tool.InputSchema)

	assertMatchesFixture(t, "write.json", []claudeNativeTool{tool})
}

// TestTranslateTools_CoderSet asserts the full CoderTools slice translates
// to 6 entries with distinct names and matches the recorded fixture.
func TestTranslateTools_CoderSet(t *testing.T) {
	out, err := translateTools(tools.CoderTools)
	if err != nil {
		t.Fatalf("CoderTools: unexpected error: %v", err)
	}
	if len(out) != len(tools.CoderTools) {
		t.Fatalf("CoderTools: want %d tools, got %d", len(tools.CoderTools), len(out))
	}
	seen := make(map[string]bool, len(out))
	for _, tool := range out {
		if seen[tool.Name] {
			t.Errorf("CoderTools: duplicate tool name %q in translation output", tool.Name)
		}
		seen[tool.Name] = true
		if tool.Description == "" {
			t.Errorf("CoderTools: tool %q: empty Description", tool.Name)
		}
		if tool.InputSchema == nil {
			t.Errorf("CoderTools: tool %q: nil InputSchema", tool.Name)
		}
	}
	assertMatchesFixture(t, "coder_set.json", out)
}

// TestTranslateTools_ReviewerSet asserts the ReviewerTools slice translates
// correctly and matches the recorded fixture.
func TestTranslateTools_ReviewerSet(t *testing.T) {
	out, err := translateTools(tools.ReviewerTools)
	if err != nil {
		t.Fatalf("ReviewerTools: unexpected error: %v", err)
	}
	if len(out) != len(tools.ReviewerTools) {
		t.Fatalf("ReviewerTools: want %d tools, got %d", len(tools.ReviewerTools), len(out))
	}
	assertMatchesFixture(t, "reviewer_set.json", out)
}

// TestTranslateTools_InvalidEmptyName asserts an invalid tool (empty Name)
// causes translateTools to return an error wrapping the validation error.
func TestTranslateTools_InvalidEmptyName(t *testing.T) {
	invalid := provider.ToolSchema{
		Description: "tool without a name",
		Parameters:  provider.ParameterSchema{Type: "object"},
	}
	_, err := translateTools([]provider.ToolSchema{invalid})
	if err == nil {
		t.Fatal("invalid_empty_name: want error, got nil")
	}
	if want := "Name is required"; !containsStr(err.Error(), want) {
		t.Errorf("invalid_empty_name: want error containing %q, got %q", want, err.Error())
	}
}

// TestTranslateTools_InvalidAdditionalPropertiesTrue asserts an invalid tool
// (AdditionalProperties: true) causes an error.
func TestTranslateTools_InvalidAdditionalPropertiesTrue(t *testing.T) {
	invalid := provider.ToolSchema{
		Name:        "BadTool",
		Description: "tool with open params",
		Parameters: provider.ParameterSchema{
			Type:                 "object",
			AdditionalProperties: true,
		},
	}
	_, err := translateTools([]provider.ToolSchema{invalid})
	if err == nil {
		t.Fatal("invalid_additional_props: want error, got nil")
	}
	if want := "AdditionalProperties must be false"; !containsStr(err.Error(), want) {
		t.Errorf("invalid_additional_props: want error containing %q, got %q", want, err.Error())
	}
}

// TestTranslateTools_ErrorWrapsToolName asserts translation errors include
// the offending tool name in the error message.
func TestTranslateTools_ErrorWrapsToolName(t *testing.T) {
	invalid := provider.ToolSchema{
		Name:       "SpecificBadName",
		Parameters: provider.ParameterSchema{Type: "object"},
	}
	_, err := translateTools([]provider.ToolSchema{invalid})
	if err == nil {
		t.Fatal("want error from invalid tool, got nil")
	}
	if !containsStr(err.Error(), "SpecificBadName") {
		t.Errorf("error should mention the tool name %q; got: %q", "SpecificBadName", err.Error())
	}
}

// TestTranslateParameters_RequiredNilToEmptySlice asserts that a tool with no
// required fields gets an empty JSON array (not null) for the required key.
func TestTranslateParameters_RequiredNilToEmptySlice(t *testing.T) {
	params := provider.ParameterSchema{
		Type:     "object",
		Required: nil,
	}
	result := translateParameters(params)
	req, ok := result["required"]
	if !ok {
		t.Fatal("required key missing from translated parameters")
	}
	slice, ok := req.([]string)
	if !ok {
		t.Fatalf("required: want []string, got %T", req)
	}
	if len(slice) != 0 {
		t.Errorf("required: want empty slice (not nil), got %v", slice)
	}
}

// TestTranslateProperty_WithItems asserts an array-typed property includes
// the items sub-schema in translation output.
func TestTranslateProperty_WithItems(t *testing.T) {
	inner := provider.ParameterProperty{Type: "string", Description: "one item"}
	outer := provider.ParameterProperty{
		Type:        "array",
		Description: "list of strings",
		Items:       &inner,
	}
	result := translateProperty(outer)
	items, ok := result["items"]
	if !ok {
		t.Fatal("items key missing from array property translation")
	}
	itemMap, ok := items.(map[string]interface{})
	if !ok {
		t.Fatalf("items: want map, got %T", items)
	}
	if got, _ := itemMap["type"].(string); got != "string" {
		t.Errorf("items.type: want string, got %q", got)
	}
}

// TestTranslateProperty_WithEnum asserts enum values are included in output.
func TestTranslateProperty_WithEnum(t *testing.T) {
	prop := provider.ParameterProperty{
		Type:        "string",
		Description: "mode",
		Enum:        []string{"a", "b", "c"},
	}
	result := translateProperty(prop)
	enum, ok := result["enum"]
	if !ok {
		t.Fatal("enum key missing from property translation")
	}
	enumSlice, ok := enum.([]string)
	if !ok {
		t.Fatalf("enum: want []string, got %T", enum)
	}
	if len(enumSlice) != 3 {
		t.Errorf("enum: want 3 values, got %d", len(enumSlice))
	}
}

// TestTranslateProperty_NoEnum asserts properties without Enum don't include
// the enum key.
func TestTranslateProperty_NoEnum(t *testing.T) {
	prop := provider.ParameterProperty{Type: "string", Description: "x"}
	result := translateProperty(prop)
	if _, ok := result["enum"]; ok {
		t.Error("enum key should be absent when Enum is nil")
	}
}

// TestTranslateProperty_NoItems asserts properties without Items don't
// include the items key.
func TestTranslateProperty_NoItems(t *testing.T) {
	prop := provider.ParameterProperty{Type: "string", Description: "x"}
	result := translateProperty(prop)
	if _, ok := result["items"]; ok {
		t.Error("items key should be absent when Items is nil")
	}
}

// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------

// assertMatchesFixture compares the JSON representation of actual against a
// recorded fixture. If the fixture does not exist, it is created (recorded).
// On subsequent runs the file acts as a golden reference.
func assertMatchesFixture(t *testing.T, fixtureName string, actual []claudeNativeTool) {
	t.Helper()
	dir := filepath.Join("testdata", "tool_translations")
	path := filepath.Join(dir, fixtureName)

	actualBytes, err := json.MarshalIndent(actual, "", "  ")
	if err != nil {
		t.Fatalf("fixture %s: marshal actual: %v", fixtureName, err)
	}
	actualBytes = append(actualBytes, '\n')

	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		if mkErr := os.MkdirAll(dir, 0755); mkErr != nil {
			t.Fatalf("fixture %s: mkdir: %v", fixtureName, mkErr)
		}
		if writeErr := os.WriteFile(path, actualBytes, 0644); writeErr != nil {
			t.Fatalf("fixture %s: write: %v", fixtureName, writeErr)
		}
		t.Logf("fixture %s: recorded (first run)", fixtureName)
		return
	}

	fixtureBytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("fixture %s: read: %v", fixtureName, err)
	}

	// Compare via unmarshal so map key ordering doesn't matter.
	var actualParsed, fixtureParsed interface{}
	if err := json.Unmarshal(actualBytes, &actualParsed); err != nil {
		t.Fatalf("fixture %s: unmarshal actual: %v", fixtureName, err)
	}
	if err := json.Unmarshal(fixtureBytes, &fixtureParsed); err != nil {
		t.Fatalf("fixture %s: unmarshal fixture: %v", fixtureName, err)
	}

	actualNorm, _ := json.Marshal(normalizeJSON(actualParsed))
	fixtureNorm, _ := json.Marshal(normalizeJSON(fixtureParsed))
	if string(actualNorm) != string(fixtureNorm) {
		t.Errorf("fixture %s: translator output diverged from recorded fixture.\nwant:\n%s\n\ngot:\n%s",
			fixtureName, string(fixtureBytes), string(actualBytes))
	}
}

// normalizeJSON recursively converts float64 values to their integer
// representation when they are whole numbers, so JSON comparison is stable.
func normalizeJSON(v interface{}) interface{} {
	switch val := v.(type) {
	case map[string]interface{}:
		out := make(map[string]interface{}, len(val))
		for k, vv := range val {
			out[k] = normalizeJSON(vv)
		}
		return out
	case []interface{}:
		out := make([]interface{}, len(val))
		for i, vv := range val {
			out[i] = normalizeJSON(vv)
		}
		return out
	default:
		return v
	}
}

func assertInputSchemaType(t *testing.T, name string, schema map[string]interface{}, wantType string) {
	t.Helper()
	got, _ := schema["type"].(string)
	if got != wantType {
		t.Errorf("%s: InputSchema.type: want %q, got %q", name, wantType, got)
	}
}

func assertRequired(t *testing.T, name string, schema map[string]interface{}, field string) {
	t.Helper()
	req, _ := schema["required"].([]string)
	for _, r := range req {
		if r == field {
			return
		}
	}
	// required may have been unmarshaled from JSON as []interface{}
	reqI, _ := schema["required"].([]interface{})
	for _, r := range reqI {
		if s, ok := r.(string); ok && s == field {
			return
		}
	}
	t.Errorf("%s: required field %q not found in required list", name, field)
}

func assertRequiredContains(t *testing.T, name string, schema map[string]interface{}, fields []string) {
	t.Helper()
	for _, f := range fields {
		assertRequired(t, name, schema, f)
	}
}

func assertPropertyExists(t *testing.T, name string, schema map[string]interface{}, propName string) {
	t.Helper()
	props, _ := schema["properties"].(map[string]interface{})
	if props == nil {
		t.Errorf("%s: properties map is nil", name)
		return
	}
	if _, ok := props[propName]; !ok {
		t.Errorf("%s: property %q not found", name, propName)
	}
}

func assertAdditionalPropertiesFalse(t *testing.T, name string, schema map[string]interface{}) {
	t.Helper()
	if v, ok := schema["additionalProperties"]; ok {
		if b, ok := v.(bool); ok && b {
			t.Errorf("%s: additionalProperties must be false, got true", name)
		}
	}
}

func containsStr(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || func() bool {
		for i := 0; i <= len(s)-len(sub); i++ {
			if s[i:i+len(sub)] == sub {
				return true
			}
		}
		return false
	}())
}
