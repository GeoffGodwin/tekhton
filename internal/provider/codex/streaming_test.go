package codex

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// makeShellStub writes a shell script to dir and returns its path.
// The stub exits 0 unless exitCode is non-zero.
func makeShellStub(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatalf("write stub %s: %v", name, err)
	}
	return p
}

// requireSh skips the test if /bin/sh is unavailable.
func requireSh(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("sh"); err != nil {
		t.Skip("sh not available")
	}
}

// TestRunCodexStreaming_EmitsTurnStart verifies that a task_started
// JSONL line emitted by the subprocess is decoded and forwarded to
// eventCh as provider.EventTurnStart before subprocess exit.
func TestRunCodexStreaming_EmitsTurnStart(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()
	// Emit task_started then exit.
	stub := makeShellStub(t, dir, "stub.sh",
		`printf '{"id":"s1","msg":{"type":"task_started","turn_id":"1"}}\n'`)

	eventCh := make(chan provider.Event, 16)
	rawStdout, events, _, exitCode, err := runCodexStreaming(
		context.Background(), "sh", []string{stub}, "prompt", eventCh, 0, nil,
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if exitCode != 0 {
		t.Fatalf("exit code = %d, want 0", exitCode)
	}

	// Channel is already closed by runCodexStreaming; drain it.
	var got []provider.Event
	for ev := range eventCh {
		got = append(got, ev)
	}

	// At least one EventTurnStart must have been received.
	var foundTurnStart bool
	for _, ev := range got {
		if ev.Kind == provider.EventTurnStart {
			foundTurnStart = true
			if ev.Turn != 1 {
				t.Errorf("EventTurnStart.Turn = %d, want 1", ev.Turn)
			}
		}
	}
	if !foundTurnStart {
		t.Errorf("no EventTurnStart in emitted events; got %v", got)
	}

	// rawStdout must contain the original line.
	if len(rawStdout) == 0 {
		t.Error("rawStdout is empty; expected the JSONL line")
	}
	// events slice must contain the decoded Event.
	if len(events) == 0 {
		t.Error("events slice is empty; expected at least one decoded event")
	}
}

// TestRunCodexStreaming_EmitsRunEnd verifies that provider.EventRunEnd
// is the last event received through the channel and that the channel
// is closed afterward (the for-range loop terminates).
func TestRunCodexStreaming_EmitsRunEnd(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()
	stub := makeShellStub(t, dir, "stub.sh",
		`printf '{"id":"s1","msg":{"type":"task_started","turn_id":"1"}}\n'
printf '{"id":"s1","msg":{"type":"task_complete","turn_id":"1","duration_ms":100}}\n'`)

	eventCh := make(chan provider.Event, 16)
	_, _, _, _, err := runCodexStreaming(
		context.Background(), "sh", []string{stub}, "prompt", eventCh, 0, nil,
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var got []provider.Event
	for ev := range eventCh {
		got = append(got, ev)
	}

	if len(got) == 0 {
		t.Fatal("no events received")
	}
	last := got[len(got)-1]
	if last.Kind != provider.EventRunEnd {
		t.Errorf("last event kind = %v, want EventRunEnd", last.Kind)
	}
}

// TestRunCodexStreaming_RawStdoutParity verifies that the streaming
// path captures byte-identical rawStdout as the blocking path against
// the same JSONL output.
func TestRunCodexStreaming_RawStdoutParity(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()
	const jsonlLine = `{"id":"s1","msg":{"type":"task_started","turn_id":"1"}}`
	stub := makeShellStub(t, dir, "stub.sh",
		"printf '"+jsonlLine+"\\n'")

	// Streaming path.
	streamRaw, _, _, _, streamErr := runCodexStreaming(
		context.Background(), "sh", []string{stub}, "prompt", nil, 0, nil,
	)
	if streamErr != nil {
		t.Fatalf("streaming path error: %v", streamErr)
	}

	// Blocking path.
	blockRaw, _, _, blockErr := runCodex(
		context.Background(), "sh", []string{stub}, "prompt", 0, nil,
	)
	if blockErr != nil {
		t.Fatalf("blocking path error: %v", blockErr)
	}

	if string(streamRaw) != string(blockRaw) {
		t.Errorf("rawStdout mismatch:\n  streaming=%q\n  blocking=%q",
			streamRaw, blockRaw)
	}
}

// TestRunCodexStreaming_ContextCancel verifies that cancelling the
// context causes runCodexStreaming to return without hanging and
// without leaking the streaming goroutine.
func TestRunCodexStreaming_ContextCancel(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()
	stub := makeShellStub(t, dir, "stub.sh", "sleep 60")

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()

	eventCh := make(chan provider.Event, 64)
	done := make(chan struct{})
	go func() {
		defer close(done)
		runCodexStreaming(ctx, "sh", []string{stub}, "prompt", eventCh, 0, nil) //nolint:errcheck
	}()

	select {
	case <-done:
		// Drain the channel so it's fully closed.
		for range eventCh {
		}
	case <-time.After(12 * time.Second):
		t.Fatal("runCodexStreaming did not return after context cancel within 12s")
	}
}

// TestRunCodexStreaming_NilChannel verifies that passing eventCh=nil
// works correctly: events are decoded and returned, no panic occurs.
func TestRunCodexStreaming_NilChannel(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()
	stub := makeShellStub(t, dir, "stub.sh",
		`printf '{"id":"s1","msg":{"type":"task_started","turn_id":"2"}}\n'`)

	rawStdout, events, _, exitCode, err := runCodexStreaming(
		context.Background(), "sh", []string{stub}, "prompt", nil, 0, nil,
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if exitCode != 0 {
		t.Fatalf("exit code = %d, want 0", exitCode)
	}
	if len(rawStdout) == 0 {
		t.Error("rawStdout is empty")
	}
	if len(events) == 0 {
		t.Error("events slice is empty; expected at least one decoded event")
	}
	if events[0].Msg.Kind != EventTaskStarted {
		t.Errorf("first event kind = %v, want EventTaskStarted", events[0].Msg.Kind)
	}
}

// TestRunCodexStreaming_MalformedJSON verifies that malformed JSONL
// lines don't crash the goroutine and are recorded as unknown events
// without emitting to the channel.
func TestRunCodexStreaming_MalformedJSON(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()
	stub := makeShellStub(t, dir, "stub.sh",
		`printf 'not valid json\n'
printf '{"id":"s1","msg":{"type":"task_started","turn_id":"1"}}\n'`)

	eventCh := make(chan provider.Event, 16)
	_, events, _, _, err := runCodexStreaming(
		context.Background(), "sh", []string{stub}, "prompt", eventCh, 0, nil,
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Drain channel.
	var emitted []provider.Event
	for ev := range eventCh {
		emitted = append(emitted, ev)
	}

	// Two raw lines → two events in events slice (1 unknown + 1 task_started).
	if len(events) < 2 {
		t.Errorf("expected ≥2 events in slice (unknown + task_started), got %d", len(events))
	}
	// Unknown event must not have been emitted to channel (only task_started + RunEnd).
	var unknownEmitted bool
	for _, ev := range emitted {
		if ev.Kind == provider.EventUnknown {
			unknownEmitted = true
		}
	}
	if unknownEmitted {
		t.Error("EventUnknown was emitted to channel; should be suppressed")
	}
}

// TestRunCodexStreaming_MultipleEvents verifies multiple event types
// are decoded in sequence and the correct provider.EventKinds are emitted.
func TestRunCodexStreaming_MultipleEvents(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()
	stub := makeShellStub(t, dir, "stub.sh",
		`printf '{"id":"s1","msg":{"type":"task_started","turn_id":"1"}}\n'
printf '{"id":"s1","msg":{"type":"agent_message","content":"hello"}}\n'
printf '{"id":"s1","msg":{"type":"task_complete","turn_id":"1","duration_ms":500}}\n'`)

	eventCh := make(chan provider.Event, 32)
	_, _, _, _, err := runCodexStreaming(
		context.Background(), "sh", []string{stub}, "prompt", eventCh, 0, nil,
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var got []provider.Event
	for ev := range eventCh {
		got = append(got, ev)
	}

	// Expect: EventTurnStart, EventAssistantChunk, EventTurnEnd, EventRunEnd.
	want := []provider.EventKind{
		provider.EventTurnStart,
		provider.EventAssistantChunk,
		provider.EventTurnEnd,
		provider.EventRunEnd,
	}
	if len(got) != len(want) {
		t.Fatalf("got %d events, want %d: %v", len(got), len(want), got)
	}
	for i, ev := range got {
		if ev.Kind != want[i] {
			t.Errorf("event[%d].Kind = %v, want %v", i, ev.Kind, want[i])
		}
	}
	// Verify the Content of the EventAssistantChunk (index 1).
	// Kind-only checks would pass even if extractAgentText were broken.
	if got[1].Content != "hello" {
		t.Errorf("event[1].Content = %q, want %q", got[1].Content, "hello")
	}
}

// TestRunCodexStreaming_EventRunEnd_DroppedWhenBufferFull documents and tests
// the existing behavior: when the channel buffer is full at the moment
// EventRunEnd is emitted, the select-default branch fires and EventRunEnd is
// silently dropped. The channel close is the authoritative completion signal —
// the for-range over the channel always terminates.
//
// Construction: buffer=1, stub emits exactly 1 event (fills the buffer).
// No concurrent consumer during the run → buffer is full at EventRunEnd.
func TestRunCodexStreaming_EventRunEnd_DroppedWhenBufferFull(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()
	// Emit exactly one mappable event so it fills the size-1 buffer.
	stub := makeShellStub(t, dir, "one_event.sh",
		`printf '{"id":"s1","msg":{"type":"task_started","turn_id":"1"}}\n'`)

	// Size-1 channel: task_started fills it; EventRunEnd hits the default branch.
	eventCh := make(chan provider.Event, 1)

	_, _, _, _, err := runCodexStreaming(
		context.Background(), "sh", []string{stub}, "prompt", eventCh, 0, nil,
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Drain the closed channel after runCodexStreaming returns.
	var got []provider.Event
	for ev := range eventCh {
		got = append(got, ev)
	}

	// The channel must be closed (for-range terminated = this line is reached).
	// EventRunEnd should be absent: the buffer was full when it was emitted.
	for _, ev := range got {
		if ev.Kind == provider.EventRunEnd {
			t.Logf("EventRunEnd was delivered despite full buffer — channel semantics may have changed")
			return
		}
	}
	// Default behavior: EventRunEnd was dropped. Channel close is the completion signal.
	t.Logf("confirmed: EventRunEnd dropped on full buffer; for-range terminated via channel close")
}

// TestRunAgent_StreamingPathUsed verifies that RunAgent with a non-nil
// EventChan drains provider.Events including the terminal EventRunEnd.
func TestRunAgent_StreamingPathUsed(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()
	stub := makeShellStub(t, dir, "stub.sh",
		`printf '{"id":"s1","msg":{"type":"task_started","turn_id":"1"}}\n'
printf '{"id":"s1","msg":{"type":"task_complete","turn_id":"1"}}\n'`)

	// Use the stub directly as the binary; it ignores codex exec args.
	p := NewWithBinary(stub)
	eventCh := make(chan provider.Event, 32)

	resCh := make(chan *provider.Result, 1)
	errCh := make(chan error, 1)
	go func() {
		res, err := p.RunAgent(context.Background(), &provider.Request{
			Prompt:    "test",
			EventChan: eventCh,
			ProviderSpecific: map[string]string{
				"codex.output_last_message": filepath.Join(dir, "last.md"),
				"codex.cwd":                dir,
			},
		})
		if err != nil {
			errCh <- err
			return
		}
		resCh <- res
	}()

	// Drain the event channel — required since RunAgent's goroutine
	// will block on sends if the consumer isn't reading.
	var got []provider.Event
	for ev := range eventCh {
		got = append(got, ev)
	}

	select {
	case err := <-errCh:
		t.Fatalf("RunAgent error: %v", err)
	case res := <-resCh:
		if res == nil {
			t.Fatal("RunAgent returned nil result")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("RunAgent timed out")
	}

	// EventRunEnd must be the last event.
	if len(got) == 0 {
		t.Fatal("no events received")
	}
	if got[len(got)-1].Kind != provider.EventRunEnd {
		t.Errorf("last event = %v, want EventRunEnd", got[len(got)-1].Kind)
	}
}

// TestRunAgent_BlockingPathFallback verifies that RunAgent with nil
// EventChan uses the blocking path and still returns a valid Result.
func TestRunAgent_BlockingPathFallback(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()
	stub := makeShellStub(t, dir, "stub.sh",
		`printf '{"id":"s1","msg":{"type":"task_started","turn_id":"1"}}\n'
printf '{"id":"s1","msg":{"type":"task_complete","turn_id":"1"}}\n'`)

	p := NewWithBinary(stub)
	res, err := p.RunAgent(context.Background(), &provider.Request{
		Prompt:    "test",
		EventChan: nil, // blocking path
		ProviderSpecific: map[string]string{
			"codex.output_last_message": filepath.Join(dir, "last.md"),
			"codex.cwd":                dir,
		},
	})
	if err != nil {
		t.Fatalf("RunAgent error: %v", err)
	}
	if res == nil {
		t.Fatal("nil result")
	}
	if res.Outcome != provider.OutcomeSuccess {
		t.Errorf("Outcome = %v, want OutcomeSuccess", res.Outcome)
	}
	if res.TurnsUsed != 1 {
		t.Errorf("TurnsUsed = %d, want 1", res.TurnsUsed)
	}
}
