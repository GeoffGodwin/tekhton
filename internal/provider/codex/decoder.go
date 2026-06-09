// Package codex — JSONL stream decoder.
// V5 m08 — decodeStream consumes JSONL stdout from runCodex.
package codex

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
)

// decodeStream consumes JSONL stdout from runCodex and returns the
// event sequence. Lenient: malformed lines yield a typed Unknown event
// rather than aborting the decode.
func decodeStream(r io.Reader) ([]Event, error) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 256*1024)

	var events []Event
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var ev Event
		if err := json.Unmarshal(line, &ev); err != nil {
			raw := json.RawMessage(line)
			ev = Event{
				Msg: EventMsg{
					Kind:    EventUnknown,
					Unknown: &raw,
					RawType: fmt.Sprintf("parse_error_line_%d", lineNo),
				},
			}
		}
		events = append(events, ev)
	}
	if err := scanner.Err(); err != nil {
		return events, fmt.Errorf("codex decoder: scan: %w", err)
	}
	return events, nil
}
