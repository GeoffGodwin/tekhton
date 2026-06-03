package notes

import (
	"path/filepath"
	"strings"
	"testing"
)

func loadGolden(t *testing.T) *Document {
	t.Helper()
	d, err := Load(filepath.Join("testdata", "golden", "round_trip.md"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	return d
}

func TestResolveActiveSuccess(t *testing.T) {
	d := loadGolden(t)
	// n02 starts Active. Run with ExitCode 0 → should resolve to Done.
	res := ResolveActive(d, ResolveOptions{ExitCode: 0, ClaimedIDs: []string{"n02"}})
	if res.ResolvedByID != 1 {
		t.Errorf("ResolvedByID = %d, want 1", res.ResolvedByID)
	}
	n02, _ := d.FindByID("n02")
	if n02.State != Done {
		t.Errorf("n02 state after resolve = %v, want Done", n02.State)
	}
}

func TestResolveActiveFailure(t *testing.T) {
	d := loadGolden(t)
	// Failure path → Active → Pending.
	res := ResolveActive(d, ResolveOptions{ExitCode: 1, ClaimedIDs: []string{"n02"}})
	if res.ResolvedByID != 1 {
		t.Errorf("ResolvedByID = %d, want 1", res.ResolvedByID)
	}
	n02, _ := d.FindByID("n02")
	if n02.State != Pending {
		t.Errorf("n02 state after failure resolve = %v, want Pending", n02.State)
	}
}

func TestClearActive(t *testing.T) {
	d := loadGolden(t)
	if n := ClearActive(d); n != 1 {
		t.Errorf("ClearActive = %d, want 1", n)
	}
	n02, _ := d.FindByID("n02")
	if n02.State != Pending {
		t.Errorf("n02 should be Pending after ClearActive")
	}
}

func TestRemoveDone(t *testing.T) {
	d := loadGolden(t)
	wantNoteCount := len(d.Notes) - 1
	removed := RemoveDone(d)
	if removed != 1 {
		t.Errorf("RemoveDone = %d, want 1", removed)
	}
	if len(d.Notes) != wantNoteCount {
		t.Errorf("after RemoveDone, len(Notes) = %d, want %d", len(d.Notes), wantNoteCount)
	}
	// n03 (Done) gone; n01 still there.
	if _, err := d.FindByID("n03"); err == nil {
		t.Errorf("n03 should be gone after RemoveDone")
	}
	if _, err := d.FindByID("n01"); err != nil {
		t.Errorf("n01 should still exist")
	}
}

func TestClaimMatching(t *testing.T) {
	d := loadGolden(t)
	ids := d.ClaimMatching("FEAT")
	if len(ids) != 2 {
		t.Fatalf("ClaimMatching(FEAT) = %v, want 2 ids", ids)
	}
	// Both feat notes should now be Active.
	for _, id := range []string{"n04", "n05"} {
		n, _ := d.FindByID(id)
		if n.State != Active {
			t.Errorf("%s state = %v, want Active", id, n.State)
		}
	}
}

func TestMarkDoneAndPending(t *testing.T) {
	d := loadGolden(t)
	if err := d.MarkDone("n01"); err != nil {
		t.Fatalf("MarkDone: %v", err)
	}
	n01, _ := d.FindByID("n01")
	if n01.State != Done {
		t.Errorf("n01 should be Done")
	}
	if err := d.MarkPending("n01"); err != nil {
		t.Fatalf("MarkPending: %v", err)
	}
	if n01.State != Pending {
		t.Errorf("n01 should be Pending")
	}
}

func TestResolveByTag(t *testing.T) {
	d := loadGolden(t)
	got := d.ResolveByTag("FEAT")
	if got != 2 {
		t.Errorf("ResolveByTag = %d, want 2", got)
	}
}

func TestUnresolvedCount_EmptyDoc(t *testing.T) {
	d := &Document{}
	if got := UnresolvedCount(d); got != 0 {
		t.Errorf("UnresolvedCount(empty) = %d, want 0", got)
	}
	if got := UnresolvedCount(nil); got != 0 {
		t.Errorf("UnresolvedCount(nil) = %d, want 0", got)
	}
}

func TestUnresolvedCount_MixedStates(t *testing.T) {
	d := loadGolden(t)
	// Golden: n01(P), n02(A), n03(D), n04(P), n05(P), n06(P) → 4 Pending.
	if got := UnresolvedCount(d); got != 4 {
		t.Errorf("UnresolvedCount = %d, want 4", got)
	}
}

func TestSelectCleanupBatch_PrioritizesFileOverlap(t *testing.T) {
	// Build a doc with five pending notes, two of which mention "foo.go".
	d := mustParseLines(t,
		"## Bugs",
		"- [ ] [BUG] fix foo.go null deref",
		"- [ ] [BUG] bar.go validation missing",
		"- [ ] [BUG] tweak foo.go logging",
		"- [ ] [BUG] baz.go style cleanup",
		"- [ ] [BUG] unrelated polish",
	)
	got := SelectCleanupBatch(d, 5, []string{"foo.go"})
	if len(got) != 5 {
		t.Fatalf("len = %d, want 5", len(got))
	}
	if !strings.Contains(got[0].Title, "foo.go") {
		t.Errorf("got[0].Title = %q, want foo.go-mentioning note first", got[0].Title)
	}
	if !strings.Contains(got[1].Title, "foo.go") {
		t.Errorf("got[1].Title = %q, want second foo.go-mentioning note", got[1].Title)
	}
}

func TestSelectCleanupBatch_RespectsSize(t *testing.T) {
	d := mustParseLines(t,
		"## Bugs",
		"- [ ] [BUG] one",
		"- [ ] [BUG] two",
		"- [ ] [BUG] three",
		"- [ ] [BUG] four",
		"- [ ] [BUG] five",
	)
	got := SelectCleanupBatch(d, 3, nil)
	if len(got) != 3 {
		t.Errorf("len = %d, want 3", len(got))
	}
	got = SelectCleanupBatch(d, 0, nil)
	if got != nil {
		t.Errorf("size=0 should return nil, got %v", got)
	}
	got = SelectCleanupBatch(nil, 5, nil)
	if got != nil {
		t.Errorf("nil doc should return nil, got %v", got)
	}
}

func TestMarkResolved_HitsFirstMatch(t *testing.T) {
	d := mustParseLines(t,
		"## Bugs",
		"- [ ] [BUG] alpha needs work",
		"- [ ] [BUG] beta needs cleanup",
		"- [ ] [BUG] gamma needs review",
	)
	if !MarkResolved(d, "beta") {
		t.Fatal("MarkResolved(beta) returned false")
	}
	if got := UnresolvedCount(d); got != 2 {
		t.Errorf("UnresolvedCount = %d, want 2 after MarkResolved", got)
	}
	// Find the beta note; it should now be Done.
	var beta *Note
	for _, n := range d.Notes {
		if strings.Contains(n.Title, "beta") {
			beta = n
			break
		}
	}
	if beta == nil || beta.State != Done {
		t.Errorf("beta state = %v, want Done", beta)
	}
}

func TestMarkResolved_NoMatch(t *testing.T) {
	d := mustParseLines(t,
		"## Bugs",
		"- [ ] [BUG] alpha",
	)
	if MarkResolved(d, "nonexistent") {
		t.Error("MarkResolved(nonexistent) returned true, want false")
	}
	if MarkResolved(nil, "alpha") {
		t.Error("MarkResolved(nil, ...) returned true, want false")
	}
	if MarkResolved(d, "") {
		t.Error("MarkResolved(d, '') returned true, want false")
	}
}

func TestMarkDeferred_HitsFirstMatch(t *testing.T) {
	d := mustParseLines(t,
		"## Bugs",
		"- [ ] [BUG] alpha",
		"- [ ] [BUG] beta",
	)
	if !MarkDeferred(d, "alpha") {
		t.Fatal("MarkDeferred(alpha) returned false")
	}
	var alpha *Note
	for _, n := range d.Notes {
		if strings.Contains(n.Title, "alpha") {
			alpha = n
			break
		}
	}
	if alpha == nil || alpha.State != Deferred {
		t.Errorf("alpha state = %v, want Deferred", alpha)
	}
	// And the line text should now carry `[DEFERRED]`.
	if !strings.Contains(d.Lines[alpha.LineIdx].Raw, "[DEFERRED]") {
		t.Errorf("line raw = %q, want [DEFERRED] marker", d.Lines[alpha.LineIdx].Raw)
	}
	// UnresolvedCount should now exclude the deferred item.
	if got := UnresolvedCount(d); got != 1 {
		t.Errorf("UnresolvedCount = %d, want 1 after MarkDeferred", got)
	}
}

func TestMarkDeferred_NoMatch(t *testing.T) {
	d := mustParseLines(t,
		"## Bugs",
		"- [ ] [BUG] alpha",
	)
	if MarkDeferred(d, "nonexistent") {
		t.Error("MarkDeferred(nonexistent) returned true, want false")
	}
	if MarkDeferred(nil, "alpha") {
		t.Error("MarkDeferred(nil, ...) returned true, want false")
	}
}

// mustParseLines is a test helper that parses a few raw lines into a
// fresh Document. Local to cleanup_test.go because the broader package
// already has fixture loaders; we want a minimal parse-from-strings
// path for the m34.2 batch + mark tests.
func mustParseLines(t *testing.T, lines ...string) *Document {
	t.Helper()
	d, err := Parse(strings.NewReader(strings.Join(lines, "\n") + "\n"))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	return d
}
