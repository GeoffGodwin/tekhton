package drift

import (
	"os"
	"path/filepath"
	"testing"
)

// loadFixture reads a fixture file pair (header.txt + body.txt) from
// testdata/<name>/ into an Artifact.
func loadFixture(t *testing.T, name string) *Artifact {
	t.Helper()
	dir := filepath.Join("testdata", name)
	header, err := os.ReadFile(filepath.Join(dir, "header.txt"))
	if err != nil {
		t.Fatalf("read header: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(dir, "body.txt"))
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return &Artifact{Header: string(header), Body: string(body)}
}

// TestRouter_CIFailingTest_IsBlocking exercises the captured m21
// closeout case: a CI test failure whose body mentions reviewer-style
// language tokens. The bash router mis-classified this as non-blocking;
// the Go router must route it as DispositionBlocking based on the
// [FAIL] header sentinel.
func TestRouter_CIFailingTest_IsBlocking(t *testing.T) {
	got := Route(loadFixture(t, "m21_router_misclassification"))
	if got != DispositionBlocking {
		t.Errorf("Route m21 fixture = %s, want %s — m21 router fix regressed", got, DispositionBlocking)
	}
}

// TestRouter_PureReviewerObservation_IsNonBlocking ensures the fix
// does NOT over-correct: artifacts without the [FAIL] sentinel whose
// body matches the non-blocking heuristic still get routed to the
// non-blocking sweep.
func TestRouter_PureReviewerObservation_IsNonBlocking(t *testing.T) {
	a := &Artifact{
		Header: "Reviewer observation — minor nitpick on naming",
		Body:   "This is a non-blocking observation about a function name pattern.",
	}
	if got := Route(a); got != DispositionNonBlocking {
		t.Errorf("Route = %s, want %s", got, DispositionNonBlocking)
	}
}

// TestRouter_NilArtifact_IsBlocking is the safety-default test.
func TestRouter_NilArtifact_IsBlocking(t *testing.T) {
	if got := Route(nil); got != DispositionBlocking {
		t.Errorf("Route(nil) = %s, want %s (safe default)", got, DispositionBlocking)
	}
}

// TestRouter_NoMatchFallsBackToBlocking checks the heuristic-miss
// path: an artifact carrying no recognised token defaults to
// DispositionBlocking.
func TestRouter_NoMatchFallsBackToBlocking(t *testing.T) {
	a := &Artifact{Header: "Generic Header", Body: "A line of generic content."}
	if got := Route(a); got != DispositionBlocking {
		t.Errorf("Route(generic) = %s, want %s (safe default)", got, DispositionBlocking)
	}
}

// TestRouter_HeaderOnlySentinel_StillBlocks asserts the sentinel is
// scanned only against Header — the m21 fix is intentional about
// where it looks.
func TestRouter_HeaderOnlySentinel_StillBlocks(t *testing.T) {
	a := &Artifact{
		Header: "[FAIL] CI test failure",
		Body:   "No reviewer tokens — body is pure failure text.",
	}
	if got := Route(a); got != DispositionBlocking {
		t.Errorf("Route = %s, want %s", got, DispositionBlocking)
	}
}

// TestRouter_BodyOnlyFailToken_NoMatch ensures the sentinel match is
// header-anchored: a [FAIL] in the Body alone should not flip the
// classification (the closeout case was specifically about the header
// carrying the signal).
func TestRouter_BodyOnlyFailToken_NoMatch(t *testing.T) {
	a := &Artifact{
		Header: "Reviewer observation — drift",
		Body:   "An earlier run included [FAIL] but that was for a different test.",
	}
	// Header matches "drift" heuristic — body sentinel ignored.
	if got := Route(a); got != DispositionNonBlocking {
		t.Errorf("Route = %s, want %s (body-only [FAIL] should not flip)", got, DispositionNonBlocking)
	}
}
