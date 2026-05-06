package state

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// FuzzStateSnapshot exercises the full Read path against arbitrary file bytes.
// The invariant is "if Read succeeds, Write must not panic and must produce a
// file Read can re-parse."
//
// Seed corpus includes:
//   - well-formed v1 JSON (the happy path)
//   - empty / single-brace / partial JSON (corrupt edge cases)
//   - V3 markdown shapes (now expected to surface ErrLegacyFormat — m10
//     retired the legacy reader; the fuzzer guards that the discriminator
//     still routes them away from the JSON path without panicking)
func FuzzStateSnapshot(f *testing.F) {
	seeds := []string{
		`{"proto":"tekhton.state.v1","run_id":"r","mode":"human"}`,
		`{"proto":"tekhton.state.v1","exit_stage":"coder","resume_task":"x","pipeline_attempt":3}`,
		`{}`,
		``,
		`{`,
		`not json and no headings`,
		// V3 markdown shapes — Read now returns ErrLegacyFormat for these.
		"## Exit Stage\ncoder\n\n## Task\nfoo\n",
		"## Exit Stage\nintake\n\n## Milestone\nnone\n\n## Task\nx\n",
		"## Exit Stage\ncoder\n## Pipeline Order\nstandard\n## Tester Mode\nverify_passing\n",
	}
	for _, s := range seeds {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, in string) {
		dir := t.TempDir()
		path := filepath.Join(dir, "PIPELINE_STATE.json")
		if err := os.WriteFile(path, []byte(in), 0o644); err != nil {
			t.Fatalf("seed write: %v", err)
		}
		store := New(path)
		snap, err := store.Read()
		if err != nil {
			// Tolerated: ErrNotFound, ErrCorrupt, ErrLegacyFormat, or a
			// wrapped variant. The invariant is "no panic on any input."
			if !errors.Is(err, ErrCorrupt) && !errors.Is(err, ErrNotFound) && !errors.Is(err, ErrLegacyFormat) {
				t.Errorf("Read returned non-typed error %T: %v", err, err)
			}
			return
		}
		if snap == nil {
			t.Fatalf("Read returned (nil, nil) for input %q", in)
		}
		// Round-trip invariant: a successful parse must re-serialize without
		// erroring. We write into a fresh file (not the input path) so the
		// fuzz input is preserved for diagnosis if Write fails.
		out := filepath.Join(dir, "round_trip.json")
		if err := New(out).Write(snap); err != nil {
			t.Fatalf("round-trip Write failed for %q: %v", in, err)
		}
		round, err := New(out).Read()
		if err != nil {
			t.Fatalf("round-trip Read failed: %v", err)
		}
		if round.ExitStage != snap.ExitStage {
			t.Errorf("ExitStage drift: in=%q out=%q", snap.ExitStage, round.ExitStage)
		}
		if round.ResumeTask != snap.ResumeTask {
			t.Errorf("ResumeTask drift: in=%q out=%q", snap.ResumeTask, round.ResumeTask)
		}
	})
}
