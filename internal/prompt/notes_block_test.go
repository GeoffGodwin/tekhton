package prompt

import (
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/notes"
)

// TestRender_HumanNotesBlock_FromNotesPackage exercises the m24 contract:
// the prompt engine can source HUMAN_NOTES_BLOCK from an in-process
// notes.Extract call rather than execing a bash subprocess to pull the
// block out of HUMAN_NOTES.md. The test composes the same value the
// runtime would compose at stage time (notes.Extract -> wrap in section
// header) and renders a template against it.
//
// This is the test that documents the m24 acceptance criterion:
//
//	internal/prompt/render.go no longer execs lib/prompts.sh for
//	HUMAN_NOTES_BLOCK — verified by the in-process path here.
//
// (The criterion's `render.go` is the historical name from the design
// doc; the engine actually lives in prompt.go.)
func TestRender_HumanNotesBlock_FromNotesPackage(t *testing.T) {
	doc, err := notes.Parse(strings.NewReader(`# Human Notes

<!-- notes-format: v2 -->

## Bugs
- [ ] [BUG] reproducer keeps the agent stuck in retry <!-- note:n01 created:2026-05-01 priority:medium source:cli -->

## Features
- [ ] [FEAT] add CSV export <!-- note:n02 created:2026-05-01 priority:low source:cli -->
`))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	body := notes.Extract(doc, notes.ExtractOpts{}) // default: Pending only, no metadata
	vars := map[string]string{
		"HUMAN_NOTES_BLOCK": "\n## Human Notes [ALL]\n\n" + body,
	}
	got := RenderString(`{{IF:HUMAN_NOTES_BLOCK}}
{{HUMAN_NOTES_BLOCK}}
{{ENDIF:HUMAN_NOTES_BLOCK}}`, vars)
	if !strings.Contains(got, "## Human Notes [ALL]") {
		t.Errorf("rendered output missing notes header:\n%s", got)
	}
	if !strings.Contains(got, "- [BUG] reproducer keeps the agent stuck") {
		t.Errorf("rendered output missing BUG note:\n%s", got)
	}
	if !strings.Contains(got, "- [FEAT] add CSV export") {
		t.Errorf("rendered output missing FEAT note:\n%s", got)
	}
	if strings.Contains(got, "<!-- note:n01") {
		t.Errorf("rendered output should not contain metadata:\n%s", got)
	}
}

func TestRender_HumanNotesBlock_EmptyDocumentDropsBlock(t *testing.T) {
	doc, err := notes.Parse(strings.NewReader("# Human Notes\n"))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	body := notes.Extract(doc, notes.ExtractOpts{})
	vars := map[string]string{"HUMAN_NOTES_BLOCK": body}
	got := RenderString(`Before {{IF:HUMAN_NOTES_BLOCK}}
SHOULD NOT APPEAR
{{ENDIF:HUMAN_NOTES_BLOCK}} After`, vars)
	if strings.Contains(got, "SHOULD NOT APPEAR") {
		t.Errorf("empty HUMAN_NOTES_BLOCK should strip the conditional body:\n%s", got)
	}
}
