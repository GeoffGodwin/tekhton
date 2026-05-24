package supervisor

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// fakeTimer counts Reset() calls so tests can assert that the decoder
// resets the activity timer exactly once per emitted line.
type fakeTimer struct {
	resets atomic.Int64
}

func (f *fakeTimer) Reset(time.Duration) bool {
	f.resets.Add(1)
	return true
}

// readFixture loads a testdata/agent_stdout/*.jsonl file. Tests use this
// over inline strings so the same fixtures can drive both decoder unit
// tests and integration tests in run_test.go.
func readFixture(t *testing.T, name string) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", "testdata", "agent_stdout"))
	if err != nil {
		t.Fatalf("abs testdata: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(root, name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return string(data)
}

// runDecode is the test harness around decode(). It collects events into a
// slice synchronously by reading from the channel in a goroutine, ensuring
// no event is dropped even when the input is buffered.
func runDecode(t *testing.T, input string, timer activityTimer) ([]event, *ringBuf) {
	t.Helper()
	rb := newRingBuf(50)
	out := make(chan event, 64)
	collected := make(chan []event, 1)
	go func() {
		var evs []event
		for ev := range out {
			evs = append(evs, ev)
		}
		collected <- evs
	}()
	var lastActivity atomic.Int64
	cfg := decoderConfig{
		timer:        timer,
		timeout:      10 * time.Millisecond,
		lastActivity: &lastActivity,
		rb:           rb,
		out:          out,
	}
	if err := decode(context.Background(), strings.NewReader(input), cfg); err != nil {
		t.Fatalf("decode: %v", err)
	}
	close(out)
	return <-collected, rb
}

// Claude CLI 2.1 reports the final turn count via num_turns on the terminal
// `type:"result"` event. The decoder must surface that as event.NumTurns so
// finalTurn() can populate AgentResultV1.TurnsUsed for the bash shim — the
// older per-line `turn` field is no longer emitted by 2.1.
func TestFinalTurn_PrefersNumTurnsFromResultEvent(t *testing.T) {
	input := `{"type":"system","subtype":"init"}` + "\n" +
		`{"type":"assistant"}` + "\n" +
		`{"type":"result","subtype":"success","num_turns":3}` + "\n"
	events, _ := runDecode(t, input, nil)
	if got := finalTurn(events); got != 3 {
		t.Errorf("finalTurn: got %d, want 3 (from num_turns on result event)", got)
	}
}

func TestDecode_ValidStream_EmitsAllEventsInOrder(t *testing.T) {
	input := readFixture(t, "valid_two_turns.jsonl")
	events, rb := runDecode(t, input, nil)

	wantTypes := []string{"turn_started", "tool_use", "turn_ended", "turn_started", "turn_ended"}
	if len(events) != len(wantTypes) {
		t.Fatalf("event count: got %d, want %d", len(events), len(wantTypes))
	}
	for i, ev := range events {
		if ev.Type != wantTypes[i] {
			t.Errorf("events[%d].Type = %q, want %q", i, ev.Type, wantTypes[i])
		}
		if ev.Raw == "" {
			t.Errorf("events[%d].Raw is empty (decoder must preserve original line)", i)
		}
	}
	if rb.len() != 5 {
		t.Errorf("ringbuf length: got %d, want 5", rb.len())
	}
	if got := finalTurn(events); got != 2 {
		t.Errorf("finalTurn: got %d, want 2", got)
	}
}

func TestDecode_MalformedLines_AreCapturedInRingBufferButNotEmitted(t *testing.T) {
	input := readFixture(t, "mixed_with_garbage.jsonl")
	events, rb := runDecode(t, input, nil)

	for _, ev := range events {
		if ev.Type == "" {
			t.Errorf("emitted event with empty type: %+v", ev)
		}
	}
	wantTypes := []string{"turn_started", "turn_ended", "turn_started", "turn_ended"}
	if len(events) != len(wantTypes) {
		t.Errorf("event count: got %d, want %d (malformed lines must be silently dropped)", len(events), len(wantTypes))
	}
	if rb.len() != 6 {
		t.Errorf("ringbuf length: got %d, want 6 (every line lands in ringbuf)", rb.len())
	}
}

func TestDecode_NoTypeField_IsDropped(t *testing.T) {
	input := readFixture(t, "no_type_field.jsonl")
	events, _ := runDecode(t, input, nil)

	for _, ev := range events {
		if ev.Type == "" {
			t.Errorf("decoder must not emit events with empty type: %+v", ev)
		}
	}
	wantTypes := []string{"turn_started", "turn_ended"}
	if len(events) != len(wantTypes) {
		t.Errorf("event count: got %d, want %d", len(events), len(wantTypes))
	}
}

func TestDecode_EmptyInput_ReturnsNoError(t *testing.T) {
	events, rb := runDecode(t, "", nil)
	if len(events) != 0 {
		t.Errorf("expected no events on empty input, got %d", len(events))
	}
	if rb.len() != 0 {
		t.Errorf("expected empty ringbuf, got len %d", rb.len())
	}
}

func TestDecode_TimerReset_FiresOncePerLine(t *testing.T) {
	input := "{\"type\":\"a\"}\nnot json\n{\"type\":\"b\",\"turn\":3}\n"
	timer := &fakeTimer{}
	events, _ := runDecode(t, input, timer)

	if got := timer.resets.Load(); got != 3 {
		t.Errorf("timer reset count: got %d, want 3 (one per line, including non-JSON)", got)
	}
	if len(events) != 2 {
		t.Errorf("event count: got %d, want 2", len(events))
	}
}

func TestDecode_LongLine_ExceedsScannerDefaultBuffer(t *testing.T) {
	// 200_000 bytes — well past bufio.Scanner's 64 KB default but inside
	// scannerMaxBuf. This is the regression guard for the "Watch For"
	// note about claude streaming events being multi-MB.
	const payloadBytes = 200_000
	payload := strings.Repeat("a", payloadBytes)
	input := "{\"type\":\"big\",\"turn\":1,\"detail\":\"" + payload + "\"}\n"
	events, _ := runDecode(t, input, nil)

	if len(events) != 1 {
		t.Fatalf("event count: got %d, want 1 (long line should not be dropped)", len(events))
	}
	if events[0].Type != "big" {
		t.Errorf("type: got %q, want big", events[0].Type)
	}
	if len(events[0].Raw) < payloadBytes {
		t.Errorf("Raw length: got %d, want >= %d", len(events[0].Raw), payloadBytes)
	}
}

func TestDecode_LineUpdatesLastActivity(t *testing.T) {
	rb := newRingBuf(10)
	out := make(chan event, 4)
	var last atomic.Int64
	last.Store(0)
	cfg := decoderConfig{
		timer:        &fakeTimer{},
		timeout:      10 * time.Millisecond,
		lastActivity: &last,
		rb:           rb,
		out:          out,
	}
	go func() {
		_ = decode(context.Background(), strings.NewReader("{\"type\":\"x\"}\n"), cfg)
		close(out)
	}()
	for range out {
	}
	if last.Load() == 0 {
		t.Error("lastActivity must be updated on each line")
	}
}

// Claude CLI 2.1 packs the diagnostic surface onto its terminal `result`
// event — permission_denials[], subtype, terminal_reason, api_error_status.
// resultDiagnostics is the boundary between "raw event soup" and the typed
// fields AgentResultV1 surfaces to bash; if the JSON tag/field mapping
// regresses, post-mortem of a "did nothing" run silently loses the most
// useful signal we have (permission_denials count).
func TestResultDiagnostics_ExtractsAllFieldsFromTerminalResultEvent(t *testing.T) {
	input := `{"type":"system","subtype":"init"}` + "\n" +
		`{"type":"assistant"}` + "\n" +
		`{"type":"result","subtype":"error_during_execution","terminal_reason":"error","api_error_status":"529","permission_denials":[{"tool":"Write"},{"tool":"Edit"},{"tool":"Bash"}],"num_turns":4}` + "\n"
	events, _ := runDecode(t, input, nil)
	subtype, terminal, apiErr, denials := resultDiagnostics(events)
	if subtype != "error_during_execution" {
		t.Errorf("subtype: got %q, want error_during_execution", subtype)
	}
	if terminal != "error" {
		t.Errorf("terminal_reason: got %q, want error", terminal)
	}
	if apiErr != "529" {
		t.Errorf("api_error_status: got %q, want 529", apiErr)
	}
	if denials != 3 {
		t.Errorf("permission_denials count: got %d, want 3", denials)
	}
}

func TestResultDiagnostics_NoResultEvent_ReturnsZeroValues(t *testing.T) {
	input := `{"type":"system","subtype":"init"}` + "\n" +
		`{"type":"assistant"}` + "\n"
	events, _ := runDecode(t, input, nil)
	subtype, terminal, apiErr, denials := resultDiagnostics(events)
	if subtype != "" || terminal != "" || apiErr != "" || denials != 0 {
		t.Errorf("expected all zero values when no result event present, got %q/%q/%q/%d",
			subtype, terminal, apiErr, denials)
	}
}

// Claude 2.1's system/api_retry event reports retry_delay_ms — the upcoming
// silent window while the CLI back-pedals from a 429/5xx. The decoder must
// extend the activity timer past that window; without this, a retry that
// would have recovered on its own gets killed by the activity timeout and
// the supervisor reports "activity_timeout" instead of letting the run
// finish.
func TestDecode_APIRetryEvent_ExtendsActivityTimer(t *testing.T) {
	input := `{"type":"system","subtype":"api_retry","retry_delay_ms":5000,"attempt":1,"max_retries":3}` + "\n"
	timer := &fakeTimer{}
	events, _ := runDecode(t, input, timer)
	if len(events) != 1 {
		t.Fatalf("event count: got %d, want 1", len(events))
	}
	// One reset from the generic per-line reset, one from the api_retry
	// extension — total 2. Plain bare-bones reset (no extension) would
	// give 1.
	if got := timer.resets.Load(); got != 2 {
		t.Errorf("timer reset count: got %d, want 2 (per-line + api_retry extension)", got)
	}
}

func TestDecode_APIRetryEventTopLevel_AlsoExtendsTimer(t *testing.T) {
	// Some 2.1.x point releases emit `type:"api_retry"` directly instead of
	// `type:"system",subtype:"api_retry"`. The decoder accepts both shapes
	// to avoid being broken by a CLI patch release.
	input := `{"type":"api_retry","retry_delay_ms":3000}` + "\n"
	timer := &fakeTimer{}
	runDecode(t, input, timer)
	if got := timer.resets.Load(); got != 2 {
		t.Errorf("timer reset count: got %d, want 2 (per-line + api_retry extension)", got)
	}
}

func TestDecode_ContextCancel_StopsForwarding(t *testing.T) {
	// out is intentionally unbuffered so the decoder blocks once it has
	// produced its first event; cancelling ctx must release it via the
	// select case in decode().
	rb := newRingBuf(10)
	out := make(chan event)
	var last atomic.Int64
	cfg := decoderConfig{
		timer:        &fakeTimer{},
		timeout:      time.Second,
		lastActivity: &last,
		rb:           rb,
		out:          out,
	}
	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan error, 1)
	go func() {
		done <- decode(ctx, strings.NewReader("{\"type\":\"a\"}\n{\"type\":\"b\"}\n"), cfg)
	}()
	cancel()
	select {
	case err := <-done:
		if err == nil || err == context.Canceled || strings.Contains(err.Error(), "context") {
			// OK — decoder respected cancellation.
		} else {
			t.Errorf("decode returned unexpected error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("decoder did not respect context cancel")
	}
}
