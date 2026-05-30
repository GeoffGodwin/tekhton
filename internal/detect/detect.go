// Package detect is the Go-side detection engine — m29.1 scaffolding for
// the bash detect subsystem port. Today the package exposes the Detector
// interface, Engine orchestrator, Summary contract, and one production
// detector (LanguagesDetector). m29.2 will land the remaining eight
// detectors (commands, workspaces, services, ci, infrastructure,
// test_frameworks, doc_quality, ai_artifacts) and the cutover of every
// bash caller.
//
// Read-only contract. Detectors MUST NOT write to the filesystem.
// internal/detect/readonly_test.go grep-scans the package for forbidden
// write APIs (os.Create, os.WriteFile, os.OpenFile with create/write,
// os.MkdirAll, os.Remove, os.RemoveAll, os.Rename). The Cobra CLI
// surface (cmd/tekhton/detect.go) is the only place os.Stdout writes
// are allowed; package-internal code stays pure.
//
// Languages-first invariant. The LanguagesDetector (Name() == "languages")
// MUST run before any other registered detector. Several m29.2 detectors
// (commands, services, infrastructure) consume Input.Languages /
// Input.Frameworks to disambiguate. Engine.Run guarantees this regardless
// of registration order; TestLanguagesFirstInvariant in detect_test.go
// asserts it. Document the invariant on Engine.Run so a future "let me
// reorder for clarity" PR fails red.
package detect

import (
	"context"
	"errors"
	"strconv"
	"strings"
)

// Detector is the contract every domain detector implements.
//
// All detectors are read-only — they MUST NOT write to the filesystem.
// The Engine guarantees the "languages" detector runs first; later
// detectors may consume Input.Languages and Input.Frameworks.
type Detector interface {
	Name() string
	Run(ctx context.Context, in *Input) (*Result, error)
}

// Input is the per-run bundle each detector receives. ProjectDir anchors
// every filesystem read; Languages and Frameworks are pre-populated by
// the languages detector before any other detector runs.
type Input struct {
	ProjectDir string
	Languages  []Language
	Frameworks []Framework
}

// Language is one row in the detect_languages output. Confidence is
// "high" | "medium" | "low" mirroring the bash rank.
type Language struct {
	Name       string `json:"name"`
	Confidence string `json:"confidence"`
	Manifest   string `json:"manifest"`
}

// Framework is one row in the detect_frameworks output. Kind is empty
// for build/runtime frameworks (next.js, react, etc.) and "ui" for the
// row emitted by the UI framework detector (playwright/cypress/etc.) —
// the bash detect_ui_framework counterpart.
type Framework struct {
	Name     string `json:"name"`
	Language string `json:"language"`
	Evidence string `json:"evidence"`
	Kind     string `json:"kind,omitempty"`
}

// Command is one row in the detect_commands output. m29.2 populates.
type Command struct {
	Type       string `json:"type"`
	Command    string `json:"command"`
	Source     string `json:"source"`
	Confidence string `json:"confidence"`
}

// EntryPoint is one row in the detect_entry_points output. m29.2 populates.
type EntryPoint struct {
	Path string `json:"path"`
}

// Workspace is one row in the detect_workspaces output. m29.2 populates.
type Workspace struct {
	Type        string   `json:"type"`
	Manifest    string   `json:"manifest"`
	Subprojects []string `json:"subprojects"`
}

// Service is one row in the detect_services output. m29.2 populates.
type Service struct {
	Name      string `json:"name"`
	Directory string `json:"directory"`
	TechStack string `json:"tech_stack"`
	Source    string `json:"source"`
}

// CIConfig is one row in the detect_ci_config output. m29.2 populates.
type CIConfig struct {
	System     string `json:"system"`
	Build      string `json:"build"`
	Test       string `json:"test"`
	Lint       string `json:"lint"`
	Deploy     string `json:"deploy"`
	Language   string `json:"language"`
	Confidence string `json:"confidence"`
}

// InfraItem is one row in the detect_infrastructure output. m29.2 populates.
type InfraItem struct {
	Tool       string `json:"tool"`
	Path       string `json:"path"`
	Provider   string `json:"provider"`
	Confidence string `json:"confidence"`
}

// TestFW is one row in the detect_test_frameworks output. m29.2 populates.
type TestFW struct {
	Name       string `json:"name"`
	Config     string `json:"config"`
	Confidence string `json:"confidence"`
}

// DocQuality is the assess_doc_quality output. m29.2 populates.
type DocQuality struct {
	Score   int      `json:"score"`
	Details []string `json:"details"`
}

// AIArtifact is one row in the detect_ai_artifacts output. Field order
// mirrors the bash pipe shape `TOOL|PATH|TYPE|CONFIDENCE` from
// lib/detect_ai_artifacts.sh — Kind is the JSON `type` key (Go keyword
// collision avoided in the Go identifier name only).
type AIArtifact struct {
	Tool       string `json:"tool"`
	Path       string `json:"path"`
	Kind       string `json:"type"`
	Confidence string `json:"confidence"`
}

// Result is what a Detector returns from Run — flat per-row findings
// matching the bash pipe-delimited shape. The Engine demuxes Result into
// the appropriate Summary field via attach().
type Result struct {
	Detector string
	Findings []map[string]string
}

// Summary is the unified detection output rendered by report.Render as
// markdown or by cmd/tekhton/detect.go as JSON. m29.1 populates
// ProjectDir, Languages, Frameworks. The remaining fields are stub-empty
// until m29.2 registers their detectors.
type Summary struct {
	ProjectDir     string       `json:"project_dir"`
	ProjectTypeStr string       `json:"project_type,omitempty"`
	Languages      []Language   `json:"languages"`
	Frameworks     []Framework  `json:"frameworks"`
	Commands       []Command    `json:"commands"`
	EntryPoints    []EntryPoint `json:"entry_points"`
	Workspaces     []Workspace  `json:"workspaces"`
	Services       []Service    `json:"services"`
	CI             []CIConfig   `json:"ci"`
	Infrastructure []InfraItem  `json:"infrastructure"`
	TestFrameworks []TestFW     `json:"test_frameworks"`
	DocQuality     *DocQuality  `json:"doc_quality,omitempty"`
	AIArtifacts    []AIArtifact `json:"ai_artifacts"`
}

// ProjectType returns the classification used in the "### Project Type:" report
// line. m29.1 returns Summary.ProjectTypeStr when populated, otherwise
// "custom" (the bash detect_project_type fallback). m29.2 wires the
// classifier in the engine.
func (s *Summary) ProjectType() string {
	if s == nil || s.ProjectTypeStr == "" {
		return "custom"
	}
	return s.ProjectTypeStr
}

// attach demuxes a detector Result into the appropriate Summary field.
// The commands detector emits three row kinds (command, entry_point,
// project_type); each is unpacked here so CommandsDetector remains a
// single registration site.
func (s *Summary) attach(name string, r *Result) {
	if r == nil {
		return
	}
	switch name {
	case "languages":
		// Handled in Engine.Run prior to attach to populate Input.
	case "commands":
		for _, row := range r.Findings {
			switch row["kind"] {
			case "command":
				s.Commands = append(s.Commands, Command{
					Type:       row["type"],
					Command:    row["command"],
					Source:     row["source"],
					Confidence: row["confidence"],
				})
			case "entry_point":
				s.EntryPoints = append(s.EntryPoints, EntryPoint{Path: row["path"]})
			case "project_type":
				if s.ProjectTypeStr == "" {
					s.ProjectTypeStr = row["value"]
				}
			}
		}
	case "workspaces":
		for _, row := range r.Findings {
			subs := splitCSV(row["subprojects"])
			s.Workspaces = append(s.Workspaces, Workspace{
				Type:        row["type"],
				Manifest:    row["manifest"],
				Subprojects: subs,
			})
		}
	case "services":
		for _, row := range r.Findings {
			s.Services = append(s.Services, Service{
				Name:      row["name"],
				Directory: row["directory"],
				TechStack: row["tech_stack"],
				Source:    row["source"],
			})
		}
	case "ci":
		for _, row := range r.Findings {
			s.CI = append(s.CI, CIConfig{
				System:     row["system"],
				Build:      row["build"],
				Test:       row["test"],
				Lint:       row["lint"],
				Deploy:     row["deploy"],
				Language:   row["language"],
				Confidence: row["confidence"],
			})
		}
	case "infrastructure":
		for _, row := range r.Findings {
			s.Infrastructure = append(s.Infrastructure, InfraItem{
				Tool:       row["tool"],
				Path:       row["path"],
				Provider:   row["provider"],
				Confidence: row["confidence"],
			})
		}
	case "test_frameworks":
		for _, row := range r.Findings {
			s.TestFrameworks = append(s.TestFrameworks, TestFW{
				Name:       row["name"],
				Config:     row["config"],
				Confidence: row["confidence"],
			})
		}
	case "doc_quality":
		for _, row := range r.Findings {
			score, _ := strconv.Atoi(row["score"])
			s.DocQuality = &DocQuality{
				Score:   score,
				Details: splitSemicolon(row["details"]),
			}
		}
	case "ai_artifacts":
		for _, row := range r.Findings {
			s.AIArtifacts = append(s.AIArtifacts, AIArtifact{
				Tool:       row["tool"],
				Path:       row["path"],
				Kind:       row["type"],
				Confidence: row["confidence"],
			})
		}
	}
}

func splitCSV(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := parts[:0]
	for _, p := range parts {
		if p == "" {
			continue
		}
		out = append(out, p)
	}
	return out
}

func splitSemicolon(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ";")
	out := parts[:0]
	for _, p := range parts {
		if p == "" {
			continue
		}
		out = append(out, p)
	}
	return out
}

// ErrLanguagesDetectorMissing is returned by Engine.Run when no detector
// with Name() == "languages" is registered. Several downstream detectors
// (commands, services, infrastructure) consume Input.Languages, so the
// engine refuses to run without a languages detector in place.
var ErrLanguagesDetectorMissing = errors.New("detect: no languages detector registered")

// Engine drives detector registration and per-run orchestration.
// Registration order is preserved, but the languages detector is
// dispatched first regardless of where it sits in the slice.
type Engine struct {
	detectors []Detector
	cache     map[string]*Result
}

// New returns an empty Engine. Callers register detectors via Register
// before invoking Run.
func New() *Engine {
	return &Engine{cache: make(map[string]*Result)}
}

// Register appends a Detector to the engine. The languages detector is
// dispatched first by Run regardless of registration order; the
// remaining detectors run in registration order.
func (e *Engine) Register(d Detector) {
	e.detectors = append(e.detectors, d)
}

// Run executes the registered detectors against the given project
// directory and returns a populated Summary.
//
// Languages-first invariant: the "languages" detector always runs before
// any other detector so Input.Languages and Input.Frameworks are
// populated for downstream consumers. If no languages detector is
// registered, Run returns ErrLanguagesDetectorMissing. Engine.Run
// caches each detector's Result keyed by Name(); calling Run a second
// time on the same Engine clears the cache and re-runs each detector.
func (e *Engine) Run(ctx context.Context, projectDir string) (*Summary, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	// Reset cache so the second Run produces fresh results.
	e.cache = make(map[string]*Result)

	in := &Input{ProjectDir: projectDir}
	s := &Summary{ProjectDir: projectDir}

	var langDetector Detector
	for _, d := range e.detectors {
		if d.Name() == "languages" {
			langDetector = d
			break
		}
	}
	if langDetector == nil {
		return nil, ErrLanguagesDetectorMissing
	}

	r, err := langDetector.Run(ctx, in)
	if err != nil {
		return nil, err
	}
	e.cache["languages"] = r
	in.Languages = languagesFromResult(r)
	in.Frameworks = frameworksFromResult(r)
	s.Languages = in.Languages
	s.Frameworks = in.Frameworks

	for _, d := range e.detectors {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if d.Name() == "languages" {
			continue
		}
		r, err := d.Run(ctx, in)
		if err != nil {
			return nil, err
		}
		e.cache[d.Name()] = r
		s.attach(d.Name(), r)
	}
	return s, nil
}

// CachedResult returns the most recent Result produced for the named
// detector during the last Run, or nil if the detector has not run.
// Exposed for test inspection and future cross-call cache surfacing
// (seeds-forward item; see m29.1 milestone notes).
func (e *Engine) CachedResult(name string) *Result {
	if e.cache == nil {
		return nil
	}
	return e.cache[name]
}

// languagesFromResult demuxes a languages-detector Result into the
// []Language slice that downstream consumers (Input.Languages) read.
func languagesFromResult(r *Result) []Language {
	if r == nil {
		return nil
	}
	out := make([]Language, 0, len(r.Findings))
	for _, row := range r.Findings {
		kind := row["kind"]
		if kind != "language" {
			continue
		}
		out = append(out, Language{
			Name:       row["name"],
			Confidence: row["confidence"],
			Manifest:   row["manifest"],
		})
	}
	return out
}

// frameworksFromResult demuxes a languages-detector Result into the
// []Framework slice that downstream consumers (Input.Frameworks) read.
// The languages detector emits both language and framework rows because
// the bash detect_frameworks call is logically inside the same family.
// Rows tagged kind=ui_framework become Framework{Kind: "ui"} — the JSON
// shape m29.2's bash wrappers (`_tk_detect_ui_framework`) filter on.
func frameworksFromResult(r *Result) []Framework {
	if r == nil {
		return nil
	}
	out := make([]Framework, 0, len(r.Findings))
	for _, row := range r.Findings {
		switch row["kind"] {
		case "framework":
			out = append(out, Framework{
				Name:     row["name"],
				Language: row["language"],
				Evidence: row["evidence"],
			})
		case "ui_framework":
			out = append(out, Framework{
				Name:     row["name"],
				Language: row["language"],
				Evidence: row["evidence"],
				Kind:     "ui",
			})
		}
	}
	return out
}
