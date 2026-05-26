package notes

import (
	"path/filepath"
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
