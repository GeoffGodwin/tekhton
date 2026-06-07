package review

import (
	"encoding/json"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// subprocessWarningsKey is the canonical Metadata key the m47 envelope-over-
// error rule uses to record post-verdict sub-call failures. The value is a
// JSON-encoded string array — plural because the rework + build-gate branches
// can both fail in a single specialist cycle, and we want every failure
// observable rather than letting the last one overwrite the first.
const subprocessWarningsKey = "subprocess_warnings"

// appendSubprocessWarning attaches msg to res.Metadata[subprocessWarningsKey]
// as a JSON array string. Multiple calls append rather than overwrite — the
// caller emits two warnings, the parser sees two entries. No-op when res is
// nil or msg is empty.
//
// Format: `["build gate exit 1","specialist runner: exec failed"]`. Tests in
// this package and stagerunner decode by `json.Unmarshal` so the format stays
// machine-readable across the bash↔Go seam.
func appendSubprocessWarning(res *proto.StageResultV1, msg string) {
	if res == nil || msg == "" {
		return
	}
	if res.Metadata == nil {
		res.Metadata = map[string]string{}
	}
	existing := []string{}
	if prev := res.Metadata[subprocessWarningsKey]; prev != "" {
		// Best-effort decode. If the prior value is malformed (e.g. someone
		// hand-set a scalar), treat it as the first entry of a new list.
		if err := json.Unmarshal([]byte(prev), &existing); err != nil {
			existing = []string{prev}
		}
	}
	existing = append(existing, msg)
	encoded, err := json.Marshal(existing)
	if err != nil {
		// json.Marshal of []string never errors in practice; fall back to a
		// single-quoted scalar so the field is at least observable.
		res.Metadata[subprocessWarningsKey] = msg
		return
	}
	res.Metadata[subprocessWarningsKey] = string(encoded)
}
