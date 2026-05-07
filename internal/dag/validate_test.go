package dag

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/manifest"
)

func TestValidateClean(t *testing.T) {
	body := `m01|First|pending||m01.md|
m02|Second|pending|m01|m02.md|
m03|Third|done|m01,m02|m03.md|
`
	s, dir := loadFixture(t, body)
	for _, fn := range []string{"m01.md", "m02.md", "m03.md"} {
		_ = writeFile(filepath.Join(dir, fn), "stub")
	}
	errs := s.Validate(dir)
	if len(errs) != 0 {
		t.Fatalf("Validate returned %d errors: %v", len(errs), errs)
	}
}

func TestValidateMissingDep(t *testing.T) {
	body := `m01|First|pending||m01.md|
m02|Second|pending|m_nonexistent|m02.md|
`
	s, _ := loadFixture(t, body)
	errs := s.Validate("")
	found := false
	for _, e := range errs {
		if errors.Is(e, ErrMissingDep) && e.Kind == "missing_dep" {
			found = true
			if !strings.Contains(e.Msg, "m_nonexistent") {
				t.Errorf("missing-dep msg lacks dep id: %s", e.Msg)
			}
		}
	}
	if !found {
		t.Fatalf("expected missing_dep error, got %v", errs)
	}
}

func TestValidateUnknownStatus(t *testing.T) {
	body := `m01|First|wibble||m01.md|
`
	s, _ := loadFixture(t, body)
	errs := s.Validate("")
	if len(errs) != 1 || errs[0].Kind != "unknown_status" {
		t.Fatalf("expected one unknown_status error, got %v", errs)
	}
	if !errors.Is(errs[0], ErrUnknownStatus) {
		t.Errorf("error not wrapping ErrUnknownStatus: %v", errs[0])
	}
}

func TestValidateMissingFile(t *testing.T) {
	body := `m01|First|pending||m01-present.md|
m02|Second|pending|m01|m02-absent.md|
`
	s, dir := loadFixture(t, body)
	_ = writeFile(filepath.Join(dir, "m01-present.md"), "stub")
	errs := s.Validate(dir)
	missingCount := 0
	for _, e := range errs {
		if e.Kind == "missing_file" && errors.Is(e, ErrMissingFile) {
			missingCount++
		}
	}
	if missingCount != 1 {
		t.Fatalf("expected exactly 1 missing_file error, got %d (errs=%v)", missingCount, errs)
	}
}

func TestValidateMissingFileSkippedWhenDirEmpty(t *testing.T) {
	body := `m01|First|pending||m01-absent.md|
`
	s, _ := loadFixture(t, body)
	errs := s.Validate("")
	for _, e := range errs {
		if e.Kind == "missing_file" {
			t.Fatalf("missing_file errors should be skipped when milestoneDir is empty: %v", e)
		}
	}
}

func TestValidateCycle(t *testing.T) {
	body := `m01|First|pending|m02|m01.md|
m02|Second|pending|m01|m02.md|
`
	s, _ := loadFixture(t, body)
	errs := s.Validate("")
	hasCycle := false
	for _, e := range errs {
		if errors.Is(e, ErrCycle) && e.Kind == "cycle" {
			hasCycle = true
		}
	}
	if !hasCycle {
		t.Fatalf("expected cycle error, got %v", errs)
	}
}

func TestValidateNoCycleAcrossDoneDeps(t *testing.T) {
	body := `m01|First|done||m01.md|
m02|Second|pending|m01|m02.md|
m03|Third|pending|m01,m02|m03.md|
`
	s, _ := loadFixture(t, body)
	errs := s.Validate("")
	for _, e := range errs {
		if e.Kind == "cycle" {
			t.Fatalf("unexpected cycle error: %v", e)
		}
	}
}

func TestValidationErrorWrapping(t *testing.T) {
	v := &ValidationError{Kind: "cycle", Msg: "x", Wrapped: ErrCycle}
	if v.Error() != "x" {
		t.Errorf("Error()=%q", v.Error())
	}
	if v.Unwrap() != ErrCycle {
		t.Errorf("Unwrap=%v", v.Unwrap())
	}
}

func TestValidateDuplicateID(t *testing.T) {
	// manifest.Load doesn't reject dup ids; we synthesize a Manifest with two
	// entries sharing an id to verify the duplicate detector.
	m := &manifest.Manifest{
		Path: "/tmp/x",
		Entries: []*manifest.Entry{
			{ID: "m01", Title: "A", Status: StatusPending, File: "m01.md"},
			{ID: "m01", Title: "B", Status: StatusPending, File: "m01b.md"},
		},
	}
	s := New(m)
	errs := s.Validate("")
	dup := false
	for _, e := range errs {
		if e.Kind == "duplicate_id" && errors.Is(e, ErrDuplicateID) {
			dup = true
		}
	}
	if !dup {
		t.Fatalf("expected duplicate_id error, got %v", errs)
	}
}
