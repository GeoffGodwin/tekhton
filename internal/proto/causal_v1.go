// Package proto defines the on-disk JSON envelopes used as the bash↔Go seam.
//
// causal.event.v1 is the format written to CAUSAL_LOG.jsonl. It is the
// authoritative contract between the Go writer and any reader (bash query
// layer, external tooling, future Go consumers). Field additions are allowed
// within v1 — additive only, never rename, never remove, never re-type.
package proto

import (
	"bytes"
	"encoding/json"
	"strconv"
)

// CausalProtoV1 is the proto envelope tag written into every event line.
const CausalProtoV1 = "tekhton.causal.v1"

// CausalEventV1 mirrors the bash writer's field set so that the JSONL output
// is byte-compatible (modulo the new "proto" field and per-line "ts"). Field
// names, casing, and order are part of the contract — do not reorder.
//
// Verdict and Context are stored as raw JSON so callers can pass either
// `null` (absent) or a pre-formatted JSON object (e.g. {"result":"APPROVED"}).
type CausalEventV1 struct {
	Proto     string          // always CausalProtoV1
	ID        string          // e.g. "coder.001"
	Ts        string          // RFC3339 (UTC, second precision — bash parity)
	RunID     string          // e.g. "run_20260315_100000"
	Milestone string          // current milestone ID (may be empty)
	Type      string          // event type, e.g. "stage_start"
	Stage     string          // stage name, e.g. "coder"
	Detail    string          // free-form detail string
	CausedBy  []string        // upstream event IDs
	Verdict   json.RawMessage // raw JSON or nil → "null"
	Context   json.RawMessage // raw JSON or nil → "null"
}

// MarshalLine produces a single JSONL line (no trailing newline) byte-for-byte
// compatible with the prior bash writer's output, plus a leading "proto"
// envelope field. The escape rules match bash's _json_escape exactly:
// backslash, double-quote, \n, \r, \t — and nothing else.
//
// Verdict and Context are emitted as raw JSON literals when non-nil; nil is
// written as the bare token `null`.
func (e *CausalEventV1) MarshalLine() []byte {
	var b bytes.Buffer
	b.Grow(256 + len(e.Detail))

	b.WriteString(`{"proto":`)
	writeQuoted(&b, e.Proto)
	b.WriteString(`,"id":`)
	writeQuoted(&b, e.ID)
	b.WriteString(`,"ts":`)
	writeQuoted(&b, e.Ts)
	b.WriteString(`,"run_id":`)
	writeQuoted(&b, e.RunID)
	b.WriteString(`,"milestone":`)
	writeQuoted(&b, e.Milestone)
	b.WriteString(`,"type":`)
	writeQuoted(&b, e.Type)
	b.WriteString(`,"stage":`)
	writeQuoted(&b, e.Stage)
	b.WriteString(`,"detail":`)
	writeQuoted(&b, e.Detail)

	b.WriteString(`,"caused_by":[`)
	for i, c := range e.CausedBy {
		if i > 0 {
			b.WriteByte(',')
		}
		writeQuoted(&b, c)
	}
	b.WriteByte(']')

	b.WriteString(`,"verdict":`)
	writeRawOrNull(&b, e.Verdict)
	b.WriteString(`,"context":`)
	writeRawOrNull(&b, e.Context)

	b.WriteByte('}')
	return b.Bytes()
}

// writeQuoted appends a JSON-quoted string using bash-_json_escape semantics.
// Only \, ", \n, \r, \t are escaped — matching bash byte-for-byte. Other
// control characters pass through unmodified, mirroring bash behavior.
func writeQuoted(b *bytes.Buffer, s string) {
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '\\':
			b.WriteString(`\\`)
		case '"':
			b.WriteString(`\"`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
}

// writeRawOrNull emits raw JSON or the bare token null.
func writeRawOrNull(b *bytes.Buffer, raw json.RawMessage) {
	if len(raw) == 0 {
		b.WriteString("null")
		return
	}
	b.Write(raw)
}

// Quote is exposed for testing the escape helper directly.
func Quote(s string) string {
	var b bytes.Buffer
	writeQuoted(&b, s)
	return b.String()
}

