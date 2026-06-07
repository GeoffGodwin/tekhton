package test_audit

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
)

// SymbolOptions carries the gates for the M88 stale-reference detector.
// SymbolMapEnabled corresponds to TEST_AUDIT_SYMBOL_MAP_ENABLED;
// TestMapFile/TagsFile are the structured-JSON inputs the bash version
// shelled to python3 to read. The Go port uses encoding/json directly.
type SymbolOptions struct {
	SymbolMapEnabled bool
	TestMapFile      string
	TagsFile         string
	SerenaActive     bool
}

// testMap mirrors the shape Serena writes to test_map.json:
// { "files": { "<test_file>": ["sym1", "sym2", ...] } }
// Some older layouts omit the "files" wrapper and use the top level as the
// map. The bash version handles both via `test_map.get("files", test_map)`;
// the Go port mirrors that fallback via a permissive decoder below.
type testMap struct {
	Files map[string][]string `json:"files"`
}

// tagsData mirrors Serena's tags.json shape:
//
//	{ "<source>": { "tags": { "definitions": [ { "name": "Sym" } ] } } }
//
// Older layouts may put the inner shape directly at the top key (no "tags"
// wrapper). The bash version's `entry.get("tags", entry)` handles that;
// the Go port mirrors via dual-decode below.
type tagDefinition struct {
	Name string `json:"name"`
}

type tagsEntry struct {
	Tags        tagsInner       `json:"tags"`
	Definitions []tagDefinition `json:"definitions"`
}

type tagsInner struct {
	Definitions []tagDefinition `json:"definitions"`
}

// DetectStaleSymbolRefs returns one finding per test symbol that does not
// exist in any source definition. Native Go JSON — no python shell-out.
// Gates: SymbolMapEnabled, TestMapFile set + exists, TagsFile exists. The
// SerenaActive gate is preserved as a documentation marker: callers
// pre-check it and only populate the file paths when the LSP wrote them.
func DetectStaleSymbolRefs(ctx context.Context, ac *AuditContext, opts SymbolOptions) []string {
	if ac == nil || !opts.SymbolMapEnabled || opts.TestMapFile == "" {
		if ac != nil {
			ac.SymbolFindings = nil
		}
		return nil
	}
	if _, err := os.Stat(opts.TestMapFile); err != nil {
		ac.SymbolFindings = nil
		return nil
	}
	tagsPath := opts.TagsFile
	if tagsPath == "" {
		ac.SymbolFindings = nil
		return nil
	}
	if _, err := os.Stat(tagsPath); err != nil {
		ac.SymbolFindings = nil
		return nil
	}
	if len(ac.TestFiles) == 0 {
		ac.SymbolFindings = nil
		return nil
	}

	filesMap, err := loadTestMap(opts.TestMapFile)
	if err != nil {
		ac.SymbolFindings = nil
		return nil
	}
	defined, err := loadDefinedSymbols(tagsPath)
	if err != nil {
		ac.SymbolFindings = nil
		return nil
	}

	testFileSet := make(map[string]struct{}, len(ac.TestFiles))
	for _, tf := range ac.TestFiles {
		testFileSet[tf] = struct{}{}
	}

	// Deterministic output: sort test files first (the bash version sorted
	// the audit-set explicitly via `sorted(test_files)`).
	sortedTests := make([]string, 0, len(ac.TestFiles))
	for tf := range testFileSet {
		sortedTests = append(sortedTests, tf)
	}
	sort.Strings(sortedTests)

	var findings []string
	for _, tf := range sortedTests {
		syms := filesMap[tf]
		for _, sym := range syms {
			if sym == "" {
				continue
			}
			if _, ok := defined[sym]; ok {
				continue
			}
			findings = append(findings, fmt.Sprintf(
				"STALE-SYM: %s references '%s' not found in any source definition", tf, sym))
		}
	}
	// Mirrors the bash _detect_stale_symbol_refs which APPENDS findings to
	// _AUDIT_ORPHAN_FINDINGS. Go keeps a separate slice (SymbolFindings)
	// but the orchestrator merges them so the agent prompt sees the same
	// "## Shell-Detected Orphans" block. Mirror that merge here too.
	if len(findings) > 0 {
		ac.OrphanFindings = append(ac.OrphanFindings, findings...)
	}
	ac.SymbolFindings = findings
	return findings
}

func loadTestMap(path string) (map[string][]string, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	// Try the canonical {"files": ...} layout first.
	var wrapped testMap
	if err := json.Unmarshal(body, &wrapped); err == nil && wrapped.Files != nil {
		return wrapped.Files, nil
	}
	// Fall back to top-level layout.
	var flat map[string][]string
	if err := json.Unmarshal(body, &flat); err != nil {
		return nil, err
	}
	return flat, nil
}

func loadDefinedSymbols(path string) (map[string]struct{}, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var entries map[string]json.RawMessage
	if err := json.Unmarshal(body, &entries); err != nil {
		return nil, err
	}
	defined := make(map[string]struct{}, 64)
	for _, raw := range entries {
		// Try {"tags": {"definitions": [...]}} first; fall back to flat.
		var entry tagsEntry
		if err := json.Unmarshal(raw, &entry); err == nil {
			defs := entry.Tags.Definitions
			if len(defs) == 0 {
				defs = entry.Definitions
			}
			for _, d := range defs {
				if d.Name != "" {
					defined[d.Name] = struct{}{}
				}
			}
		}
	}
	return defined, nil
}
