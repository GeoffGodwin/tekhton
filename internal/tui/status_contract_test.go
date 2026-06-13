package tui

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// m26: Contract tests for WriteInitial / WriteFinal in status.go.
//
// These functions are not in the production pipeline (tekhton tui start uses
// state.go::SaveAtomic instead), but they carry the wrong JSON field names and
// types that caused the original m26 schema-drift report. The tests pin the
// correct field names so a future re-wire cannot silently re-introduce the
// broken contract.
//
// Correct contract (matches TUIStatusV1Payload + Python renderer):
//   - JSON key "current_agent_status"  (not "agent_status")
//   - JSON key "recent_events" value must be an array of objects
//     (not an array of strings), so Python's ev.get("ts") doesn't crash
//   - Root-level "proto" key present (not "schema"), so Python's proto-check
//     can find it and promote the payload to the top level

func TestWriteInitialFieldName_CurrentAgentStatus(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tui_status.json")

	if err := WriteInitial(path, "task", []string{"intake", "coder"}); err != nil {
		t.Fatalf("WriteInitial: %v", err)
	}

	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatalf("json.Unmarshal: %v", err)
	}

	// The Python renderer reads "current_agent_status" (tui_render.py:69, 124).
	// Accepting the key at either the root (legacy shape) or inside "payload"
	// (proto-envelope shape) so this test is valid for both encoding strategies.
	rootHas := func(key string) bool {
		_, ok := doc[key]
		return ok
	}
	payloadHas := func(key string) bool {
		p, ok := doc["payload"]
		if !ok {
			return false
		}
		pm, ok := p.(map[string]any)
		if !ok {
			return false
		}
		_, ok = pm[key]
		return ok
	}

	hasCurrent := rootHas("current_agent_status") || payloadHas("current_agent_status")
	hasLegacy := rootHas("agent_status") && !payloadHas("current_agent_status")

	if !hasCurrent {
		t.Errorf("WriteInitial: field \"current_agent_status\" is absent — "+
			"Python renderer cannot read agent status; "+
			"root keys: %v", keysOf(doc))
	}
	if hasLegacy {
		t.Errorf("WriteInitial: root-level \"agent_status\" found instead of "+
			"\"current_agent_status\" — Python renderer reads the wrong field name")
	}
}

func TestWriteInitialFieldName_RecentEventsAreObjects(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tui_status.json")

	if err := WriteInitial(path, "task", nil); err != nil {
		t.Fatalf("WriteInitial: %v", err)
	}

	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	// Verify that the "recent_events" JSON value is an array whose element type
	// is compatible with map[string]any — not []string. The Go type
	// []string marshals to ["s1","s2"...], and Python's
	// ev.get("ts","") crashes with AttributeError on strings.
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil {
		t.Fatalf("json.Unmarshal raw: %v", err)
	}

	// Accept events in root OR inside "payload".
	eventsRaw, ok := raw["recent_events"]
	if !ok {
		if payloadRaw, ok2 := raw["payload"]; ok2 {
			var payload map[string]json.RawMessage
			if err := json.Unmarshal(payloadRaw, &payload); err == nil {
				eventsRaw, ok = payload["recent_events"]
			}
		}
	}
	if !ok {
		t.Fatalf("WriteInitial: \"recent_events\" field absent from emitted JSON")
	}

	// An empty array [] satisfies the type requirement — the issue only
	// surfaces when events are present. We verify the declared Go type is
	// compatible by ensuring the emitted value IS an array (not null / string).
	var events []json.RawMessage
	if err := json.Unmarshal(eventsRaw, &events); err != nil {
		t.Fatalf("WriteInitial: \"recent_events\" is not a JSON array: %v", err)
	}
	// If any elements exist they must be objects, not strings.
	for i, elem := range events {
		var s string
		if json.Unmarshal(elem, &s) == nil {
			t.Errorf("WriteInitial: recent_events[%d] is a string %q — "+
				"Python ev.get('ts') will crash; must be an object", i, s)
		}
	}
}

func TestWriteInitialFieldName_UsesProtoNotSchema(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tui_status.json")

	if err := WriteInitial(path, "task", nil); err != nil {
		t.Fatalf("WriteInitial: %v", err)
	}

	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatalf("json.Unmarshal: %v", err)
	}

	// Python _read_status() looks for doc.get("proto") — if missing it treats
	// the whole document as legacy bare-payload.  For the initial status to be
	// upgraded to the proto-envelope path (with correct field promotion), the
	// key must be "proto", not "schema".
	_, hasProto := doc["proto"]
	_, hasSchema := doc["schema"]

	if hasSchema && !hasProto {
		t.Errorf("WriteInitial: uses \"schema\" key instead of \"proto\" — "+
			"Python _read_status() cannot find the proto tag and will "+
			"treat the document as a legacy bare-payload, losing the "+
			"payload promotion step")
	}
}

func TestWriteFinalFieldName_CurrentAgentStatus(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tui_status.json")

	if err := WriteFinal(path, "success"); err != nil {
		t.Fatalf("WriteFinal: %v", err)
	}

	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatalf("json.Unmarshal: %v", err)
	}

	// Same contract as WriteInitial — Python reads current_agent_status.
	rootHas := func(key string) bool { _, ok := doc[key]; return ok }
	payloadHas := func(key string) bool {
		p, ok := doc["payload"]
		if !ok {
			return false
		}
		pm, ok := p.(map[string]any)
		if !ok {
			return false
		}
		_, ok = pm[key]
		return ok
	}

	hasCurrent := rootHas("current_agent_status") || payloadHas("current_agent_status")
	if !hasCurrent {
		t.Errorf("WriteFinal: field \"current_agent_status\" is absent; "+
			"root keys: %v", keysOf(doc))
	}
}

// keysOf returns the top-level keys of a map for error messages.
func keysOf(m map[string]any) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	return ks
}
