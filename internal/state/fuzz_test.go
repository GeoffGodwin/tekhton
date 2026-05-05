package state

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// FuzzStateSnapshot exercises the full Read path against arbitrary file bytes.
// The invariant the milestone calls out is "if Read succeeds, Write must not
// panic and must produce a file Read can re-parse." This catches bugs in
// either the JSON path (Store.Read) or the legacy markdown reader before they
// regress the V3 → V4 resume path.
//
// Seed corpus includes:
//   - well-formed v1 JSON (the happy path)
//   - empty / single-brace / partial JSON (corrupt edge cases)
//   - V3 markdown shapes (the legacy reader's responsibility)
//
// Without the V3 markdown seeds, the legacy reader's parser surface is
// uncovered and a regression there would silently break in-flight state files.
func FuzzStateSnapshot(f *testing.F) {
	seeds := []string{
		`{"proto":"tekhton.state.v1","run_id":"r","mode":"human"}`,
		`{"proto":"tekhton.state.v1","exit_stage":"coder","resume_task":"x","pipeline_attempt":3}`,
		`{}`,
		``,
		`{`,
		`not json and no headings`,
		// V3 markdown — minimal recognized form.
		"## Exit Stage\ncoder\n\n## Task\nfoo\n",
		// V3 markdown with orchestration block + error classification.
		"## Exit Stage\ncoder\n\n## Task\nrun X\n\n## Orchestration Context\nPipeline attempt: 4\nCumulative agent calls: 12\n\n## Error Classification\nCategory: UPSTREAM\nSubcategory: api_500\nTransient: true\nRecovery: Retry\n",
		// V3 markdown with milestone "none" sentinel.
		"## Exit Stage\nintake\n\n## Milestone\nnone\n\n## Task\nx\n",
		// V3 markdown with all extra-field headings.
		"## Exit Stage\ncoder\n## Pipeline Order\nstandard\n## Tester Mode\nverify_passing\n## Human Mode\ntrue\n## Human Notes Tag\nBUG\n",
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
			// Tolerated: ErrNotFound (won't fire — file exists), ErrCorrupt,
			// or a wrapped variant. The invariant is "no panic on any input."
			if !errors.Is(err, ErrCorrupt) && !errors.Is(err, ErrNotFound) {
				// Any other error type is unexpected from Read on existing data.
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
		// Re-read and compare a stable shape (ExitStage + ResumeTask cover
		// both JSON and legacy paths without depending on Extra ordering).
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

// FuzzParseLegacyMarkdown targets parseLegacyMarkdown directly so the fuzzer
// reaches the legacy reader's parser surface independent of Read's
// JSON/markdown discriminator. This is the parser the V3 → V4 cutover relies
// on; until m05 deletes it, fuzzing keeps it honest.
func FuzzParseLegacyMarkdown(f *testing.F) {
	seeds := []string{
		"## Exit Stage\ncoder\n",
		"## Task\nfoo\n## Notes\nbar\n",
		"## Orchestration Context\nPipeline attempt: 1\nCumulative agent calls: 0\n",
		"## Error Classification\nCategory: X\n### Last Agent Output\nhello\nworld\n",
		"## Files Present\nfile1\nfile2\n",
		"",
		"plain text",
		"## ", // bare heading
	}
	for _, s := range seeds {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, in string) {
		// Invariant: never panic. On a successful parse, the snapshot must
		// have the proto envelope set (parseLegacyMarkdown initializes it).
		snap, ok := parseLegacyMarkdown([]byte(in))
		if !ok {
			return
		}
		if snap == nil {
			t.Fatalf("parseLegacyMarkdown returned (nil, true) for %q", in)
		}
		if snap.Proto == "" {
			t.Errorf("legacy parse left Proto empty: %+v", snap)
		}
	})
}
