package security

import (
	"errors"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/drift"
)

// fakeHumanAction records every Append call without touching disk. Used to
// assert the (source, description) the Escalator sent.
type fakeHumanAction struct {
	ensureCalls int
	appends     []struct{ source, desc string }
	ensureErr   error
	appendErr   error
}

func (f *fakeHumanAction) EnsureFile() error {
	f.ensureCalls++
	return f.ensureErr
}

func (f *fakeHumanAction) Append(source, desc string) error {
	f.appends = append(f.appends, struct{ source, desc string }{source, desc})
	return f.appendErr
}

func TestHandleUnfixable_EmptyBlockShortCircuits(t *testing.T) {
	fake := &fakeHumanAction{}
	e := &Escalator{HumanAction: fake}
	cont, err := e.HandleUnfixable("escalate", "", "some-task")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !cont {
		t.Errorf("empty block must continue, got cont=false")
	}
	if len(fake.appends) != 0 {
		t.Errorf("empty block must not call Append, got %d call(s)", len(fake.appends))
	}
}

func TestHandleUnfixable_EscalateBranch(t *testing.T) {
	const block = "- [HIGH] outdated openssl\n"
	fake := &fakeHumanAction{}
	e := &Escalator{HumanAction: fake}
	cont, err := e.HandleUnfixable("escalate", block, "task")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !cont {
		t.Errorf("escalate must continue, got cont=false")
	}
	if len(fake.appends) != 1 {
		t.Fatalf("expected 1 Append, got %d", len(fake.appends))
	}
	got := fake.appends[0]
	if got.source != "security" {
		t.Errorf("source = %q, want \"security\"", got.source)
	}
	wantDesc := "Unfixable security findings require human review:\n" + block
	if got.desc != wantDesc {
		t.Errorf("desc mismatch:\n got  %q\n want %q", got.desc, wantDesc)
	}
}

// TestHandleUnfixable_EmptyPolicyDefaultsToEscalate covers the bash
// `${SECURITY_UNFIXABLE_POLICY:-escalate}` default — an unset (empty) policy
// is the same as "escalate", not "halt" or "unknown".
func TestHandleUnfixable_EmptyPolicyDefaultsToEscalate(t *testing.T) {
	const block = "- [HIGH] thing\n"
	fake := &fakeHumanAction{}
	e := &Escalator{HumanAction: fake}
	cont, err := e.HandleUnfixable("", block, "task")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !cont {
		t.Errorf("empty policy must continue (default escalate), got cont=false")
	}
	if len(fake.appends) != 1 {
		t.Fatalf("expected 1 Append, got %d", len(fake.appends))
	}
	wantDesc := "Unfixable security findings require human review:\n" + block
	if fake.appends[0].desc != wantDesc {
		t.Errorf("empty-policy default did not match escalate desc")
	}
}

func TestHandleUnfixable_HaltBranch(t *testing.T) {
	const block = "- [CRITICAL] thing\n"
	fake := &fakeHumanAction{}
	e := &Escalator{HumanAction: fake}
	cont, err := e.HandleUnfixable("halt", block, "task")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if cont {
		t.Errorf("halt must NOT continue, got cont=true")
	}
	if len(fake.appends) != 0 {
		t.Errorf("halt must not call Append (M35.2's stage writes state), got %d call(s)", len(fake.appends))
	}
	if fake.ensureCalls != 0 {
		t.Errorf("halt must not touch the human-action file, got %d EnsureFile call(s)", fake.ensureCalls)
	}
}

func TestHandleUnfixable_WaiverBranch(t *testing.T) {
	const block = "- [HIGH] thing\n"
	fake := &fakeHumanAction{}
	e := &Escalator{HumanAction: fake}
	cont, err := e.HandleUnfixable("waiver", block, "task")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !cont {
		t.Errorf("waiver must continue, got cont=false")
	}
	if len(fake.appends) != 0 {
		t.Errorf("waiver must not call Append, got %d call(s)", len(fake.appends))
	}
}

func TestHandleUnfixable_UnknownPolicyDefaultsToEscalateWithDifferentPrefix(t *testing.T) {
	const block = "- [HIGH] thing\n"
	fake := &fakeHumanAction{}
	e := &Escalator{HumanAction: fake}
	cont, err := e.HandleUnfixable("bogus-policy", block, "task")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !cont {
		t.Errorf("unknown policy must continue (default escalate), got cont=false")
	}
	if len(fake.appends) != 1 {
		t.Fatalf("expected 1 Append, got %d", len(fake.appends))
	}
	// Operator-visible: the unknown-policy branch uses a shorter prefix
	// without the "require human review" phrasing.
	wantDesc := "Unfixable security findings:\n" + block
	if fake.appends[0].desc != wantDesc {
		t.Errorf("unknown-policy desc mismatch:\n got  %q\n want %q",
			fake.appends[0].desc, wantDesc)
	}
}

// The escalate branch returns (true, err) on writer failures — matches the
// bash `... || warn "..."` semantics that the pipeline continues even when
// the human-action file write fails. Callers log the error and proceed.
func TestHandleUnfixable_PropagatesEnsureFileError(t *testing.T) {
	wantErr := errors.New("disk full")
	fake := &fakeHumanAction{ensureErr: wantErr}
	e := &Escalator{HumanAction: fake}
	cont, err := e.HandleUnfixable("escalate", "- [HIGH] x\n", "task")
	if !errors.Is(err, wantErr) {
		t.Errorf("err must wrap ensure error, got %v", err)
	}
	if !cont {
		t.Errorf("on ensure error, cont must remain true (pipeline keeps going, caller warns)")
	}
}

func TestHandleUnfixable_PropagatesAppendError(t *testing.T) {
	wantErr := errors.New("append failed")
	fake := &fakeHumanAction{appendErr: wantErr}
	e := &Escalator{HumanAction: fake}
	cont, err := e.HandleUnfixable("escalate", "- [HIGH] x\n", "task")
	if !errors.Is(err, wantErr) {
		t.Errorf("err must wrap append error, got %v", err)
	}
	if !cont {
		t.Errorf("on append error, cont must remain true (pipeline keeps going, caller warns)")
	}
}

// TestNewEscalator_WiresRealHumanAction confirms the constructor binds the
// HUMAN_ACTION_REQUIRED.md path under projectDir/.tekhton/ and that the
// returned Escalator can append through the real drift.HumanAction.
func TestNewEscalator_WiresRealHumanAction(t *testing.T) {
	dir := t.TempDir()
	e := NewEscalator(dir)
	_, err := e.HandleUnfixable("escalate", "- [HIGH] real-write\n", "task")
	if err != nil {
		t.Fatalf("real-write err: %v", err)
	}
	haPath := filepath.Join(dir, ".tekhton", "HUMAN_ACTION_REQUIRED.md")
	ha := drift.NewHumanAction(haPath)
	n, err := ha.CountUnchecked()
	if err != nil {
		t.Fatalf("count err: %v", err)
	}
	if n != 1 {
		t.Errorf("expected 1 unchecked item in human-action file, got %d", n)
	}
}

func TestNewEscalatorWithPath_HonorsCustomPath(t *testing.T) {
	dir := t.TempDir()
	haPath := filepath.Join(dir, "custom-human-action.md")
	e := NewEscalatorWithPath(haPath)
	if _, err := e.HandleUnfixable("escalate", "- [HIGH] x\n", "task"); err != nil {
		t.Fatalf("err: %v", err)
	}
	if _, err := drift.NewHumanAction(haPath).CountUnchecked(); err != nil {
		t.Errorf("custom path was not written: %v", err)
	}
}
