package provider

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestProfileFor_Builtins — qwen-local gets conservative defaults; claude/codex
// are zero profiles (m22 acceptance #1).
func TestProfileFor_Builtins(t *testing.T) {
	t.Setenv("PROJECT_DIR", t.TempDir()) // no override files
	t.Setenv("CHARS_PER_TOKEN", "4")

	q := ProfileFor("qwen-local")
	if q.MaxTurnsFactor != 1.5 {
		t.Errorf("qwen-local MaxTurnsFactor: want 1.5, got %v", q.MaxTurnsFactor)
	}
	if q.ContextBudgetPct != 25 {
		t.Errorf("qwen-local ContextBudgetPct: want 25, got %d", q.ContextBudgetPct)
	}
	if q.MaxPromptChars != 24000*4 {
		t.Errorf("qwen-local MaxPromptChars: want %d, got %d", 24000*4, q.MaxPromptChars)
	}
	if q.FormatReinforcement == "" {
		t.Error("qwen-local FormatReinforcement should be set")
	}

	for _, name := range []string{"claude", "codex"} {
		if got := ProfileFor(name); got != (Profile{}) {
			t.Errorf("ProfileFor(%q): want zero Profile, got %+v", name, got)
		}
	}
}

// TestProfileFor_OverrideMerge — an override file changes a field; a malformed
// line is skipped without failing (m22 acceptance #2).
func TestProfileFor_OverrideMerge(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PROJECT_DIR", dir)
	t.Setenv("CHARS_PER_TOKEN", "4")
	pdir := filepath.Join(dir, ".claude", "provider_profiles")
	if err := os.MkdirAll(pdir, 0o755); err != nil {
		t.Fatal(err)
	}
	conf := "MAX_TURNS_FACTOR=2.0\nthis is a malformed line\nUNKNOWN_KEY=whatever\n"
	if err := os.WriteFile(filepath.Join(pdir, "qwen-local.conf"), []byte(conf), 0o644); err != nil {
		t.Fatal(err)
	}

	p := ProfileFor("qwen-local")
	if p.MaxTurnsFactor != 2.0 {
		t.Errorf("override MAX_TURNS_FACTOR: want 2.0, got %v", p.MaxTurnsFactor)
	}
	// Other built-ins still present (merge, not replace).
	if p.ContextBudgetPct != 25 {
		t.Errorf("ContextBudgetPct should retain built-in 25, got %d", p.ContextBudgetPct)
	}
	// Malformed + unknown lines did not fail the run (we got here) and did not
	// corrupt the parsed value.
}

// TestProfile_Apply_ScalesTurns — MaxTurns=20 × factor 1.5 = 30 (acceptance #3).
func TestProfile_Apply_ScalesTurns(t *testing.T) {
	p := Profile{MaxTurnsFactor: 1.5}
	req := &Request{MaxTurns: 20, Prompt: "hi"}
	out, _ := p.Apply(req)
	if out.MaxTurns != 30 {
		t.Errorf("scaled MaxTurns: want 30, got %d", out.MaxTurns)
	}
	if req.MaxTurns != 20 {
		t.Errorf("original request mutated: MaxTurns now %d (Apply must copy)", req.MaxTurns)
	}
}

// TestProfile_Apply_ClampsPrompt — prompt over MaxPromptChars is clamped, a
// note is returned, and the original request is untouched (acceptance #4).
func TestProfile_Apply_ClampsPrompt(t *testing.T) {
	p := Profile{MaxPromptChars: 10}
	orig := strings.Repeat("x", 50)
	req := &Request{Prompt: orig}
	out, note := p.Apply(req)
	if len(out.Prompt) != 10 {
		t.Errorf("clamped prompt len: want 10, got %d", len(out.Prompt))
	}
	if note == "" {
		t.Error("expected a clamp note when truncation occurs")
	}
	if !strings.Contains(note, "50") || !strings.Contains(note, "10") {
		t.Errorf("clamp note should record 50->10; got %q", note)
	}
	if req.Prompt != orig {
		t.Error("original request prompt mutated — Apply must copy (parity rule)")
	}
}

// TestProfile_Apply_Reinforcement — FormatReinforcement is prepended only when
// set (acceptance #5).
func TestProfile_Apply_Reinforcement(t *testing.T) {
	withRF := Profile{FormatReinforcement: "REINFORCE"}
	out, _ := withRF.Apply(&Request{Prompt: "body"})
	if !strings.HasPrefix(out.Prompt, "REINFORCE") {
		t.Errorf("reinforcement not prepended: %q", out.Prompt)
	}
	if !strings.Contains(out.Prompt, "body") {
		t.Error("original prompt body lost after reinforcement")
	}

	zero := Profile{}
	out2, _ := zero.Apply(&Request{Prompt: "body"})
	if out2.Prompt != "body" {
		t.Errorf("zero profile should not alter prompt; got %q", out2.Prompt)
	}
}
