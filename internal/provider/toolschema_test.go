package provider_test

import (
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// validTool returns a minimally valid ToolSchema for use as a test baseline.
func validTool() provider.ToolSchema {
	return provider.ToolSchema{
		Name:        "TestTool",
		Description: "A test tool.",
		Parameters: provider.ParameterSchema{
			Type:                 "object",
			AdditionalProperties: false,
		},
	}
}

func TestValidateToolSchema_Valid(t *testing.T) {
	if err := provider.ValidateToolSchema(validTool()); err != nil {
		t.Errorf("valid tool: want nil error, got %v", err)
	}
}

func TestValidateToolSchema_EmptyName(t *testing.T) {
	ts := validTool()
	ts.Name = ""
	err := provider.ValidateToolSchema(ts)
	if err == nil {
		t.Fatal("empty_name: want error, got nil")
	}
	if want := "Name is required"; !contains(err.Error(), want) {
		t.Errorf("empty_name: want message containing %q, got %q", want, err.Error())
	}
}

func TestValidateToolSchema_EmptyDescription(t *testing.T) {
	ts := validTool()
	ts.Description = ""
	err := provider.ValidateToolSchema(ts)
	if err == nil {
		t.Fatal("empty_description: want error, got nil")
	}
	if want := "Description is required"; !contains(err.Error(), want) {
		t.Errorf("empty_description: want message containing %q, got %q", want, err.Error())
	}
}

func TestValidateToolSchema_ParametersTypeNotObject(t *testing.T) {
	ts := validTool()
	ts.Parameters.Type = "string"
	err := provider.ValidateToolSchema(ts)
	if err == nil {
		t.Fatal("type_not_object: want error, got nil")
	}
	if want := `Parameters.Type must be "object"`; !contains(err.Error(), want) {
		t.Errorf("type_not_object: want message containing %q, got %q", want, err.Error())
	}
}

func TestValidateToolSchema_AdditionalPropertiesTrue(t *testing.T) {
	ts := validTool()
	ts.Parameters.AdditionalProperties = true
	err := provider.ValidateToolSchema(ts)
	if err == nil {
		t.Fatal("additional_props_true: want error, got nil")
	}
	if want := "AdditionalProperties must be false"; !contains(err.Error(), want) {
		t.Errorf("additional_props_true: want message containing %q, got %q", want, err.Error())
	}
}

func TestValidateToolSchema_ParametersTypeEmpty(t *testing.T) {
	ts := validTool()
	ts.Parameters.Type = ""
	err := provider.ValidateToolSchema(ts)
	if err == nil {
		t.Fatal("empty_type: want error, got nil (empty Type should fail object check)")
	}
}

// TestToolSchema_StructFields asserts the exported types have the fields the
// milestone spec defines — a compile-time canary against accidental renames.
func TestToolSchema_StructFields(t *testing.T) {
	ts := provider.ToolSchema{
		Name:        "X",
		Description: "Y",
		Parameters: provider.ParameterSchema{
			Type:                 "object",
			Properties:           map[string]provider.ParameterProperty{"p": {Type: "string", Description: "d"}},
			Required:             []string{"p"},
			AdditionalProperties: false,
		},
		BehaviorHints: provider.BehaviorHints{
			ModifiesFiles:  true,
			Reads:          false,
			ExecutesShell:  false,
			MaxOutputBytes: 4096,
			LongRunning:    false,
		},
	}
	if ts.Name != "X" {
		t.Errorf("Name field not accessible")
	}
	if ts.BehaviorHints.MaxOutputBytes != 4096 {
		t.Errorf("BehaviorHints.MaxOutputBytes not accessible")
	}
	prop := ts.Parameters.Properties["p"]
	if prop.Type != "string" {
		t.Errorf("ParameterProperty.Type not accessible")
	}
}

// TestParameterProperty_ItemsField asserts the Items pointer field is usable
// for array-typed parameters.
func TestParameterProperty_ItemsField(t *testing.T) {
	inner := &provider.ParameterProperty{Type: "string", Description: "item"}
	outer := provider.ParameterProperty{
		Type:        "array",
		Description: "list of strings",
		Items:       inner,
	}
	if outer.Items == nil {
		t.Fatal("Items: want non-nil pointer, got nil")
	}
	if outer.Items.Type != "string" {
		t.Errorf("Items.Type: want string, got %q", outer.Items.Type)
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(sub) == 0 ||
		func() bool {
			for i := 0; i <= len(s)-len(sub); i++ {
				if s[i:i+len(sub)] == sub {
					return true
				}
			}
			return false
		}())
}
