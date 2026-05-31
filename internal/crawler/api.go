package crawler

// Public API surface for callers outside this package (today: only
// cmd/tekhton/crawler.go and tests). Wrapping the private helpers
// behind exported aliases keeps the orchestrator-internal vocabulary
// (lowercase names) intact while giving consumers a stable seam.
//
// These wrappers also document the read-only contract: each function
// only enumerates / reads the project tree, never writes.

// ListTrackedFiles returns the repo-relative file list — git ls-files
// output if available, find-based walk otherwise. Mirrors
// lib/crawler.sh::_list_tracked_files.
func ListTrackedFiles(projectDir string) []string {
	return listTrackedFiles(projectDir)
}

// BuildFileInventory walks the file list and counts lines per file.
// Returns an *Inventory with one InventoryEntry per file.
func BuildFileInventory(projectDir string, files []string) *Inventory {
	return buildFileInventory(projectDir, files)
}

// ParseDependencies runs the seven manifest parsers (npm / Cargo /
// pyproject / go.mod / Gemfile / Gradle / pom) and the monorepo
// sub-project sweep. Returns the full graph (manifests + key deps).
func ParseDependencies(projectDir string) (*DependencyGraph, error) {
	return parseDependencies(projectDir)
}

// SampleFiles returns the priority-ordered sample list within budget.
// designFile is the optional architecture-doc candidate (typically
// `$DESIGN_FILE`).
func SampleFiles(projectDir string, files []string, budget int, designFile string) []Sample {
	return sampleFiles(projectDir, files, budget, designFile)
}

// IsBinary returns true when path looks like a binary file (null-byte
// heuristic in the first 512 bytes OR a known binary extension).
func IsBinary(path string) bool {
	return isBinary(path)
}

// AnnotatePackage maps a well-known package name to a short purpose
// string. Returns "" for unknown packages.
func AnnotatePackage(pkg string) string {
	return annotatePackage(pkg)
}

// ConfigPurpose returns the annotation for a config file path, or ""
// when the file is not a recognized config.
func ConfigPurpose(relPath string) string {
	return configPurpose(relPath)
}
