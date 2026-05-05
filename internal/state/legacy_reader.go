// REMOVE IN m05.
//
// parseLegacyMarkdown reads V3-era PIPELINE_STATE.md files (heading-delimited
// markdown) and converts them into a StateSnapshotV1. It exists so a single
// Tekhton upgrade does not orphan in-flight resume state.
//
// The parser recognizes the heading set the pre-m03 bash heredoc wrote — see
// lib/state.sh in the m02 commit. Anything not in this map is dropped: the
// migration is one-way (JSON → markdown back-compat is explicitly out of
// scope per the milestone "Watch For" notes), and most legacy fields are
// either ephemeral or already covered by Extra.
//
// On the next Update the legacy sentinel is stripped and the file is
// rewritten as JSON, so a state file is at most one Read away from being
// fully migrated.
package state

import (
	"bufio"
	"bytes"
	"strconv"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// legacyHeading -> snapshot field setter. The setter receives the trimmed
// content block (everything between this heading and the next "## " line)
// and applies it to snap. Setters tolerate missing/empty content.
type legacySetter func(snap *proto.StateSnapshotV1, content string)

// directField returns a setter that writes to a string field selected by
// closure. Most legacy headings just copy the trimmed first line into a
// scalar field, so we factor out the common shape.
func directField(set func(*proto.StateSnapshotV1, string)) legacySetter {
	return func(snap *proto.StateSnapshotV1, content string) {
		val := firstLine(content)
		if val == "" {
			return
		}
		set(snap, val)
	}
}

func extraField(key string) legacySetter {
	return func(snap *proto.StateSnapshotV1, content string) {
		val := firstLine(content)
		if val == "" {
			return
		}
		ensureExtra(snap)[key] = val
	}
}

// legacyMap covers the heading set the pre-m03 writer emitted.
var legacyMap = map[string]legacySetter{
	"## Exit Stage":         directField(func(s *proto.StateSnapshotV1, v string) { s.ExitStage = v }),
	"## Exit Reason":        directField(func(s *proto.StateSnapshotV1, v string) { s.ExitReason = v }),
	"## Resume Command":     directField(func(s *proto.StateSnapshotV1, v string) { s.ResumeFlag = v }),
	"## Task":               directField(func(s *proto.StateSnapshotV1, v string) { s.ResumeTask = v }),
	"## Notes":              directField(func(s *proto.StateSnapshotV1, v string) { s.Notes = v }),
	"## Milestone":          directField(func(s *proto.StateSnapshotV1, v string) { s.MilestoneID = v }),
	"## Pipeline Order":     extraField("pipeline_order"),
	"## Tester Mode":        extraField("tester_mode"),
	"## Human Mode":         extraField("human_mode"),
	"## Human Notes Tag":    extraField("human_notes_tag"),
	"## Current Note Line":  extraField("current_note_line"),
	"## Current Note ID":    extraField("current_note_id"),
	"## Human Single Note":  extraField("human_single_note"),
	"## Files Present":      func(s *proto.StateSnapshotV1, c string) { ensureExtra(s)["files_present"] = strings.TrimSpace(c) },
	"## Orchestration Context": parseOrchestrationContext,
	"## Error Classification":  parseErrorClassification,
}

// parseLegacyMarkdown returns (snap, true) on a successful parse. False
// indicates the file did not look like the V3 markdown format and the
// caller should fall back to ErrCorrupt. The minimum required signal is at
// least one recognized heading — empty/garbage files trip the false path.
func parseLegacyMarkdown(data []byte) (*proto.StateSnapshotV1, bool) {
	snap := &proto.StateSnapshotV1{Proto: proto.StateProtoV1}

	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	var (
		currentHeading string
		buf            strings.Builder
		matched        int
	)
	flush := func() {
		if currentHeading == "" {
			return
		}
		setter, ok := legacyMap[currentHeading]
		if !ok {
			return
		}
		setter(snap, buf.String())
		matched++
	}

	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "## ") {
			flush()
			currentHeading = strings.TrimRight(line, " \t")
			buf.Reset()
			continue
		}
		buf.WriteString(line)
		buf.WriteByte('\n')
	}
	flush()

	if matched == 0 {
		return nil, false
	}
	if snap.MilestoneID == "none" {
		snap.MilestoneID = ""
	}
	return snap, true
}

// parseOrchestrationContext decodes the "Pipeline attempt: N", "Cumulative
// agent calls: N" and friends. Lines like "(not in --complete mode)" or any
// "### Prior Attempt Outcomes" sub-section are preserved as a free-form
// extra blob so a future reader can still see the context.
func parseOrchestrationContext(snap *proto.StateSnapshotV1, content string) {
	var attemptLog []string
	for _, line := range strings.Split(strings.TrimSpace(content), "\n") {
		if strings.HasPrefix(line, "Pipeline attempt:") {
			snap.PipelineAttempt = atoiTail(line)
		} else if strings.HasPrefix(line, "Cumulative agent calls:") {
			snap.AgentCallsTotal = atoiTail(line)
		} else if strings.HasPrefix(line, "Cumulative turns:") {
			ensureExtra(snap)["cumulative_turns"] = strings.TrimSpace(strings.TrimPrefix(line, "Cumulative turns:"))
		} else if strings.HasPrefix(line, "Wall-clock elapsed:") {
			ensureExtra(snap)["wall_clock_elapsed"] = strings.TrimSpace(strings.TrimPrefix(line, "Wall-clock elapsed:"))
		} else if line != "" {
			attemptLog = append(attemptLog, line)
		}
	}
	if len(attemptLog) > 0 {
		ensureExtra(snap)["orchestration_extra"] = strings.Join(attemptLog, "\n")
	}
}

// parseErrorClassification decodes the "Category: X / Subcategory: Y /
// Transient: Z / Recovery: ... / ### Last Agent Output" block into a single
// ErrorRecordV1 entry.
func parseErrorClassification(snap *proto.StateSnapshotV1, content string) {
	t := strings.TrimSpace(content)
	if t == "" || strings.HasPrefix(t, "(no error classification") {
		return
	}
	rec := proto.ErrorRecordV1{}
	var lastOut strings.Builder
	inLast := false
	for _, line := range strings.Split(t, "\n") {
		switch {
		case strings.HasPrefix(line, "Category:"):
			rec.Category = strings.TrimSpace(strings.TrimPrefix(line, "Category:"))
		case strings.HasPrefix(line, "Subcategory:"):
			rec.Subcategory = strings.TrimSpace(strings.TrimPrefix(line, "Subcategory:"))
		case strings.HasPrefix(line, "Transient:"):
			rec.Transient = strings.TrimSpace(strings.TrimPrefix(line, "Transient:")) == "true"
		case strings.HasPrefix(line, "Recovery:"):
			rec.Recovery = strings.TrimSpace(strings.TrimPrefix(line, "Recovery:"))
		case strings.HasPrefix(line, "### Last Agent Output"):
			inLast = true
		case inLast:
			if lastOut.Len() > 0 {
				lastOut.WriteByte('\n')
			}
			lastOut.WriteString(line)
		}
	}
	rec.LastOutput = strings.TrimSpace(lastOut.String())
	if rec.Category == "" && rec.LastOutput == "" {
		return
	}
	snap.Errors = append(snap.Errors, rec)
}

func ensureExtra(snap *proto.StateSnapshotV1) map[string]string {
	if snap.Extra == nil {
		snap.Extra = make(map[string]string, 8)
	}
	return snap.Extra
}

func firstLine(s string) string {
	t := strings.TrimSpace(s)
	if t == "" {
		return ""
	}
	if idx := strings.IndexByte(t, '\n'); idx >= 0 {
		return strings.TrimSpace(t[:idx])
	}
	return t
}

// atoiTail extracts a trailing integer from a line like "Pipeline attempt: 3".
// Returns 0 on parse failure (legacy callers tolerated empty values).
func atoiTail(line string) int {
	idx := strings.LastIndexByte(line, ' ')
	if idx < 0 {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(line[idx+1:]))
	if err != nil {
		return 0
	}
	return n
}
