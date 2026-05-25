package tui

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// State is the in-memory representation of one TUI status snapshot. The bash
// implementation kept ~60 globals (_TUI_ACTIVE, _TUI_PID, _TUI_CURRENT_*, …);
// m23 collapses them into one struct held by the supervisor (in-process) or
// reconstituted from tui_status.json on every CLI invocation (out-of-process).
//
// Cross-subprocess persistence: every `tekhton tui ...` callsite loads the
// status file, mutates the payload, writes it back atomically (tmpfile +
// os.Rename). The legacy bash writer paid the same per-mutation snapshot cost;
// the added read is a stat+open+decode on a typically <8KB file, far cheaper
// than the stage transition or agent call gating each mutation.
type State struct {
	Payload proto.TUIStatusV1Payload
	// PauseStartedAt0 is true when payload.PauseStartedAt should serialize as
	// literal 0 rather than emit-on-set. Helps preserve the bash invariant
	// that pause_started_at = 0 means "not paused" rather than "paused at
	// epoch 0".
	// (Field reserved for future use; omitted from JSON by Marshal directly.)

	// CycleCounters tracks per-label monotonic lifecycle ids (bash
	// _TUI_STAGE_CYCLE). Persisted alongside the payload so cross-subprocess
	// allocations stay monotonic.
	CycleCounters map[string]int `json:"cycle_counters,omitempty"`

	// ClosedLifecycleIDs records ids that have been ended so late agent ticks
	// arriving after the stage closed can be dropped (bash
	// _TUI_CLOSED_LIFECYCLE_IDS).
	ClosedLifecycleIDs map[string]bool `json:"closed_lifecycle_ids,omitempty"`

	// SuppressWrite is the batched-write semaphore (bash _TUI_SUPPRESS_WRITE).
	// > 0 means the caller is composing a multi-step mutation and the file
	// should not be rewritten until the count drops to zero. Not normally
	// useful in the subprocess model (each CLI call is atomic) but preserved
	// for symmetry with the bash semantics.
	SuppressWrite int `json:"suppress_write,omitempty"`

	// LivenessCount counts writes since the last sidecar liveness probe.
	// Mirrors bash _TUI_WRITE_COUNT_SINCE_LIVENESS.
	LivenessCount int `json:"liveness_count,omitempty"`

	// PipelineStartTS is the bash _TUI_PIPELINE_START_TS — captured at
	// `tekhton tui start` so pipeline_elapsed_secs is derived on every write.
	PipelineStartTS int64 `json:"pipeline_start_ts,omitempty"`
}

// ErrNotFound is returned by Load when the status file does not exist. The
// canonical "no state yet" signal — callers may construct a fresh State and
// SaveAtomic instead of treating this as a hard error.
var ErrNotFound = errors.New("tui: status file not found")

// NewState returns an empty State with all collections initialized so JSON
// marshaling produces `[]` / `{}` rather than `null`. Named NewState rather
// than New to avoid colliding with sidecar.New in this package.
func NewState() *State {
	return &State{
		Payload: proto.TUIStatusV1Payload{
			Version:        1,
			Attempt:        1,
			MaxAttempts:    1,
			StagesComplete: []proto.TUIStageEntry{},
			RecentEvents:   []proto.TUIEventEntry{},
			StageOrder:     []string{},
			ActionItems:    []proto.TUIActionItem{},
			RunMode:        "task",
			CurrentAgentStatus: "idle",
		},
		CycleCounters:      map[string]int{},
		ClosedLifecycleIDs: map[string]bool{},
	}
}

// Load reads tui_status.json from path and reconstitutes a State. Returns
// ErrNotFound when the file is missing — callers should construct a fresh
// State and proceed. Any other error (decode failure, IO error) is surfaced.
//
// Accepts both the legacy bare-payload shape (root keys: milestone, task, …)
// and the m23 envelope shape ({proto, run_id, payload}). The envelope's
// auxiliary fields (cycle_counters, closed_lifecycle_ids, etc.) are read
// from the root JSON object on either path.
func Load(path string) (*State, error) {
	if path == "" {
		return nil, fmt.Errorf("tui: status file path required")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("tui: read %s: %w", path, err)
	}
	return Decode(data)
}

// Decode is the in-memory variant of Load. Exposed so callers can drive
// State reconstitution from a byte slice without touching the filesystem.
func Decode(data []byte) (*State, error) {
	if len(data) == 0 {
		return NewState(), nil
	}
	// Peek the envelope. If a "proto" field is present and equals
	// TUIStatusV1, treat the payload as nested. Otherwise treat the whole
	// document as a bare payload (legacy shape).
	var peek struct {
		Proto   string          `json:"proto"`
		Payload json.RawMessage `json:"payload"`
	}
	if err := json.Unmarshal(data, &peek); err != nil {
		return nil, fmt.Errorf("tui: decode envelope: %w", err)
	}

	st := NewState()
	if peek.Proto == proto.TUIStatusV1 && len(peek.Payload) > 0 {
		if err := json.Unmarshal(peek.Payload, &st.Payload); err != nil {
			return nil, fmt.Errorf("tui: decode payload: %w", err)
		}
	} else {
		// Legacy bare-payload path.
		if err := json.Unmarshal(data, &st.Payload); err != nil {
			return nil, fmt.Errorf("tui: decode legacy payload: %w", err)
		}
	}

	// Auxiliary fields stored alongside the envelope. Decoded into a thin
	// struct so an unexpected envelope shape doesn't break Load.
	var aux struct {
		CycleCounters      map[string]int  `json:"cycle_counters"`
		ClosedLifecycleIDs map[string]bool `json:"closed_lifecycle_ids"`
		SuppressWrite      int             `json:"suppress_write"`
		LivenessCount      int             `json:"liveness_count"`
		PipelineStartTS    int64           `json:"pipeline_start_ts"`
	}
	if err := json.Unmarshal(data, &aux); err == nil {
		if aux.CycleCounters != nil {
			st.CycleCounters = aux.CycleCounters
		}
		if aux.ClosedLifecycleIDs != nil {
			st.ClosedLifecycleIDs = aux.ClosedLifecycleIDs
		}
		st.SuppressWrite = aux.SuppressWrite
		st.LivenessCount = aux.LivenessCount
		st.PipelineStartTS = aux.PipelineStartTS
	}

	// Defaults for collections that the bash side guaranteed to be non-nil.
	if st.Payload.StagesComplete == nil {
		st.Payload.StagesComplete = []proto.TUIStageEntry{}
	}
	if st.Payload.RecentEvents == nil {
		st.Payload.RecentEvents = []proto.TUIEventEntry{}
	}
	if st.Payload.StageOrder == nil {
		st.Payload.StageOrder = []string{}
	}
	if st.Payload.ActionItems == nil {
		st.Payload.ActionItems = []proto.TUIActionItem{}
	}
	return st, nil
}

// SaveAtomic writes the state to path via tmpfile + os.Rename so a partially
// written status file never reaches the sidecar reader. Mirrors the bash
// _tui_write_status atomic-write convention.
//
// The output document is the m23 envelope shape, with auxiliary fields
// (cycle_counters, etc.) flattened to the root so a sibling-process loader
// reconstitutes them without ambiguity.
func (s *State) SaveAtomic(path string) error {
	if path == "" {
		return fmt.Errorf("tui: status file path required")
	}
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		_ = os.MkdirAll(dir, 0o755)
	}
	data, err := s.Encode()
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("tui: write tmp %s: %w", tmp, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("tui: rename %s → %s: %w", tmp, path, err)
	}
	return nil
}

// Encode marshals the state as the m23 envelope shape with auxiliary fields
// at the root.
func (s *State) Encode() ([]byte, error) {
	// Build an ordered map so the proto/run_id/payload triplet appears at
	// the top of the JSON. We use a struct rather than map[string]any so
	// field order is deterministic.
	type out struct {
		Proto              string                   `json:"proto"`
		RunID              string                   `json:"run_id"`
		Payload            proto.TUIStatusV1Payload `json:"payload"`
		CycleCounters      map[string]int           `json:"cycle_counters,omitempty"`
		ClosedLifecycleIDs map[string]bool          `json:"closed_lifecycle_ids,omitempty"`
		SuppressWrite      int                      `json:"suppress_write,omitempty"`
		LivenessCount      int                      `json:"liveness_count,omitempty"`
		PipelineStartTS    int64                    `json:"pipeline_start_ts,omitempty"`
	}
	doc := out{
		Proto:              proto.TUIStatusV1,
		RunID:              s.Payload.RunID,
		Payload:            s.Payload,
		CycleCounters:      s.CycleCounters,
		ClosedLifecycleIDs: s.ClosedLifecycleIDs,
		SuppressWrite:      s.SuppressWrite,
		LivenessCount:      s.LivenessCount,
		PipelineStartTS:    s.PipelineStartTS,
	}
	return json.Marshal(doc)
}

// AllocateLifecycleID bumps the per-label cycle counter and returns
// "<label>#<cycle>". Mirrors bash _tui_alloc_lifecycle_id.
func (s *State) AllocateLifecycleID(label string) string {
	if label == "" {
		return ""
	}
	if s.CycleCounters == nil {
		s.CycleCounters = map[string]int{}
	}
	s.CycleCounters[label]++
	id := fmt.Sprintf("%s#%d", label, s.CycleCounters[label])
	s.Payload.CurrentLifecycleID = id
	return id
}

// MarkLifecycleClosed records id as closed so subsequent agent updates carrying
// that id can be dropped. Bash equivalent: _TUI_CLOSED_LIFECYCLE_IDS[id]=1.
func (s *State) MarkLifecycleClosed(id string) {
	if id == "" {
		return
	}
	if s.ClosedLifecycleIDs == nil {
		s.ClosedLifecycleIDs = map[string]bool{}
	}
	s.ClosedLifecycleIDs[id] = true
}

// IsLifecycleClosed reports whether id has been marked closed.
func (s *State) IsLifecycleClosed(id string) bool {
	if id == "" || s.ClosedLifecycleIDs == nil {
		return false
	}
	return s.ClosedLifecycleIDs[id]
}

// SortedStageOrder returns a copy of stage_order with duplicates removed. The
// bash side appended idempotently; we preserve that contract here for callers
// that want a clean snapshot.
func (s *State) SortedStageOrder() []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range s.Payload.StageOrder {
		if seen[s] {
			continue
		}
		seen[s] = true
		out = append(out, s)
	}
	sort.SliceStable(out, func(i, j int) bool {
		return strings.Compare(out[i], out[j]) < 0
	})
	return out
}
