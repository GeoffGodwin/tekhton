// Package codex — Streaming subprocess wrapper.
// V5 m10 — runCodexStreaming emits provider.Event as Codex writes JSONL.
package codex

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// runCodexStreaming invokes codex like runCodex (m07) but pipes stdout
// through a goroutine that parses each line and emits provider.Event to
// eventCh as events arrive. Returns when the subprocess exits and the
// streaming goroutine has drained the final partial buffer.
//
// Contract: eventCh receives provider.EventRunEnd as the FINAL event,
// then is closed. Callers MUST drain eventCh with a for-range loop.
// eventCh may be nil — in that case events are still decoded and
// returned but nothing is emitted to a channel.
//
// envExtra, when non-nil, is appended to os.Environ() for the subprocess.
// Used by m11 auth wiring; pass nil to inherit the process environment.
func runCodexStreaming(
	parent context.Context,
	bin string,
	args []string,
	prompt string,
	eventCh chan<- provider.Event,
	timeout time.Duration,
	envExtra []string,
) (rawStdout []byte, events []Event, stderr []byte, exitCode int, err error) {
	ctx := parent
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(parent, timeout)
		defer cancel()
	}

	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Stdin = strings.NewReader(prompt)
	if len(envExtra) > 0 {
		cmd.Env = append(os.Environ(), envExtra...)
	}

	stdoutPipe, pipeErr := cmd.StdoutPipe()
	if pipeErr != nil {
		return nil, nil, nil, -1, fmt.Errorf("stdout pipe: %w", pipeErr)
	}
	var errBuf bytes.Buffer
	cmd.Stderr = &errBuf
	cmd.WaitDelay = 5 * time.Second

	if startErr := cmd.Start(); startErr != nil {
		return nil, nil, nil, -1, fmt.Errorf("start: %w", startErr)
	}

	var (
		rawBuf    bytes.Buffer
		eventsBuf []Event
		mu        sync.Mutex
		scanDone  = make(chan struct{})
	)

	go func() {
		defer close(scanDone)
		scanner := bufio.NewScanner(stdoutPipe)
		scanner.Buffer(make([]byte, 0, 64*1024), 256*1024)
		for scanner.Scan() {
			lineBytes := scanner.Bytes()
			// Copy — scanner reuses its buffer.
			line := make([]byte, len(lineBytes))
			copy(line, lineBytes)

			// Tee to rawBuf for postmortem capture.
			mu.Lock()
			rawBuf.Write(line)
			rawBuf.WriteByte('\n')
			mu.Unlock()

			// Decode + map.
			var codexEv Event
			if jsonErr := json.Unmarshal(line, &codexEv); jsonErr == nil {
				mu.Lock()
				eventsBuf = append(eventsBuf, codexEv)
				mu.Unlock()
				if eventCh != nil {
					if provEv, ok := mapToProviderEvent(codexEv); ok {
						select {
						case eventCh <- provEv:
						case <-ctx.Done():
							return
						}
					}
				}
			} else {
				// Malformed JSON — record as unknown, don't emit.
				raw := json.RawMessage(line)
				mu.Lock()
				eventsBuf = append(eventsBuf, Event{
					Msg: EventMsg{
						Kind:    EventUnknown,
						Unknown: &raw,
						RawType: "parse_error",
					},
				})
				mu.Unlock()
			}
		}
	}()

	// Per os/exec docs: "Wait will close the pipe after seeing the command
	// exit ... it is thus incorrect to call Wait before all reads from the
	// pipe have completed." Closing the parent's read end discards anything
	// still in the OS pipe buffer, which surfaced as a flaky 0-event read in
	// TestRunCodexStreaming_MalformedJSON. Drain the scanner first, then Wait.
	// Subprocess hangs are still bounded by exec.CommandContext (kills on
	// ctx.Done) and cmd.WaitDelay set above.
	<-scanDone
	waitErr := cmd.Wait()

	// Emit EventRunEnd then close the channel — even on errors.
	if eventCh != nil {
		select {
		case eventCh <- provider.Event{Kind: provider.EventRunEnd, Timestamp: time.Now()}:
		default:
		}
		close(eventCh)
	}

	mu.Lock()
	rawStdout = append(rawStdout, rawBuf.Bytes()...)
	events = append(events, eventsBuf...)
	mu.Unlock()

	if waitErr != nil {
		if exitErr, ok := waitErr.(*exec.ExitError); ok {
			return rawStdout, events, errBuf.Bytes(), exitErr.ExitCode(), nil
		}
		return rawStdout, events, errBuf.Bytes(), -1, fmt.Errorf("wait: %w", waitErr)
	}
	return rawStdout, events, errBuf.Bytes(), 0, nil
}

// parseTurnID converts a turn_id string (typically "1", "2", ...) to int.
// Returns 0 on parse failure.
func parseTurnID(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

// formatInt formats an int64 as a decimal string.
func formatInt(n int64) string {
	return strconv.FormatInt(n, 10)
}

// extractAgentText returns the text content from an agent_message event.
func extractAgentText(ev Event) string {
	if ev.Msg.AgentMessage == nil {
		return ""
	}
	return ev.Msg.AgentMessage.Content
}
