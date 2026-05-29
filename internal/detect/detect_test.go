package detect

import (
	"context"
	"errors"
	"testing"
)

// stubDetector is a configurable test double.
type stubDetector struct {
	name string
	hook func(*Input) (*Result, error)
}

func (s stubDetector) Name() string { return s.name }
func (s stubDetector) Run(_ context.Context, in *Input) (*Result, error) {
	return s.hook(in)
}

// TestLanguagesFirstInvariant is the load-bearing m29.1 contract test.
// Several m29.2 detectors (commands, services, infrastructure) consume
// Input.Languages to disambiguate, so the languages detector MUST run
// before any other detector regardless of registration order. The test
// registers a non-language detector first, then the language detector,
// and asserts the language detector ran first.
func TestLanguagesFirstInvariant(t *testing.T) {
	var order []string
	e := New()
	e.Register(stubDetector{
		name: "z_last_by_name",
		hook: func(in *Input) (*Result, error) {
			order = append(order, "z_last_by_name")
			if len(in.Languages) == 0 {
				t.Errorf("z_last_by_name ran before languages: Input.Languages was empty")
			}
			return &Result{Detector: "z_last_by_name"}, nil
		},
	})
	e.Register(stubDetector{
		name: "languages",
		hook: func(_ *Input) (*Result, error) {
			order = append(order, "languages")
			return &Result{
				Detector: "languages",
				Findings: []map[string]string{
					{"kind": "language", "name": "go", "confidence": "high", "manifest": "go.mod"},
				},
			}, nil
		},
	})
	if _, err := e.Run(context.Background(), "."); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(order) != 2 || order[0] != "languages" || order[1] != "z_last_by_name" {
		t.Errorf("expected order [languages, z_last_by_name]; got %v", order)
	}
}

// TestEngineRun_ErrorWithoutLanguagesDetector asserts the engine refuses
// to run when no languages detector is registered. Downstream detectors
// would see an empty Input.Languages and silently mis-disambiguate.
func TestEngineRun_ErrorWithoutLanguagesDetector(t *testing.T) {
	e := New()
	e.Register(stubDetector{
		name: "commands",
		hook: func(_ *Input) (*Result, error) { return &Result{}, nil },
	})
	if _, err := e.Run(context.Background(), "."); !errors.Is(err, ErrLanguagesDetectorMissing) {
		t.Errorf("expected ErrLanguagesDetectorMissing; got %v", err)
	}
}

// TestEngineRun_PropagatesDetectorError verifies that a downstream
// detector error short-circuits the run.
func TestEngineRun_PropagatesDetectorError(t *testing.T) {
	boom := errors.New("boom")
	e := New()
	e.Register(stubDetector{
		name: "languages",
		hook: func(_ *Input) (*Result, error) {
			return &Result{Detector: "languages"}, nil
		},
	})
	e.Register(stubDetector{
		name: "commands",
		hook: func(_ *Input) (*Result, error) { return nil, boom },
	})
	if _, err := e.Run(context.Background(), "."); !errors.Is(err, boom) {
		t.Errorf("expected boom error; got %v", err)
	}
}

// TestEngineCachedResult_PerRun verifies that calling Run resets and
// repopulates the cache. The cache is exposed for test inspection (and a
// future seeds-forward "cross-call cache surfacing" item).
func TestEngineCachedResult_PerRun(t *testing.T) {
	calls := 0
	e := New()
	e.Register(stubDetector{
		name: "languages",
		hook: func(_ *Input) (*Result, error) {
			calls++
			return &Result{Detector: "languages"}, nil
		},
	})
	if _, err := e.Run(context.Background(), "."); err != nil {
		t.Fatalf("Run 1: %v", err)
	}
	if e.CachedResult("languages") == nil {
		t.Error("cache miss after Run 1")
	}
	if _, err := e.Run(context.Background(), "."); err != nil {
		t.Fatalf("Run 2: %v", err)
	}
	if calls != 2 {
		t.Errorf("expected 2 detector invocations; got %d (cache leaked across Runs)", calls)
	}
	if e.CachedResult("commands") != nil {
		t.Error("unregistered detector should not appear in cache")
	}
}

// TestSummary_ProjectType_Fallback covers the "custom" fallback when no
// project type has been assigned.
func TestSummary_ProjectType_Fallback(t *testing.T) {
	var s *Summary
	if got := s.ProjectType(); got != "custom" {
		t.Errorf("nil summary: expected 'custom'; got %q", got)
	}
	s = &Summary{}
	if got := s.ProjectType(); got != "custom" {
		t.Errorf("empty summary: expected 'custom'; got %q", got)
	}
	s.ProjectTypeStr = "web-app"
	if got := s.ProjectType(); got != "web-app" {
		t.Errorf("populated summary: expected 'web-app'; got %q", got)
	}
}
