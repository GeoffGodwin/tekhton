package detect

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// DocQualityDetector ports lib/detect_doc_quality.sh::assess_doc_quality.
// Produces a 0-100 score plus a list of subscore details — used by the
// report formatter to render the Documentation Quality section.
type DocQualityDetector struct{}

// Name returns the canonical detector name.
func (DocQualityDetector) Name() string { return "doc_quality" }

// Run executes documentation quality scoring.
func (DocQualityDetector) Run(_ context.Context, in *Input) (*Result, error) {
	dq := assessDocQuality(in.ProjectDir)
	r := &Result{Detector: "doc_quality"}
	r.Findings = append(r.Findings, map[string]string{
		"score":   strconv.Itoa(dq.Score),
		"details": strings.Join(dq.Details, ";"),
	})
	return r, nil
}

func assessDocQuality(dir string) *DocQuality {
	score := 0
	var details []string

	readmeScore, readmeDetail := scoreReadme(dir)
	score += readmeScore
	details = append(details, readmeDetail)

	contribScore := scoreContributing(dir)
	score += contribScore
	details = append(details, "contributing:"+strconv.Itoa(contribScore)+"/15")

	apiScore := scoreAPI(dir)
	score += apiScore
	details = append(details, "api-docs:"+strconv.Itoa(apiScore)+"/15")

	archScore := scoreArchitecture(dir)
	score += archScore
	details = append(details, "architecture:"+strconv.Itoa(archScore)+"/20")

	inlineScore := assessInlineDocs(dir)
	score += inlineScore
	details = append(details, "inline:"+strconv.Itoa(inlineScore)+"/20")

	if score > 100 {
		score = 100
	}
	if score < 0 {
		score = 0
	}
	return &DocQuality{Score: score, Details: details}
}

func scoreReadme(dir string) (int, string) {
	var readmeFile string
	for _, c := range []string{"README.md", "README.rst", "README.txt", "README"} {
		if fileExists(filepath.Join(dir, c)) {
			readmeFile = filepath.Join(dir, c)
			break
		}
	}
	if readmeFile == "" {
		return 0, "readme:0/30(missing)"
	}
	body := readFile(readmeFile)
	lines := strings.Count(body, "\n")
	if !strings.HasSuffix(body, "\n") && body != "" {
		lines++
	}
	score := 5
	if lines > 20 {
		score = 10
	}
	if lines > 100 {
		score = 15
	}
	sectionCount := countSections(body)
	if sectionCount >= 3 {
		score += 5
	}
	if strings.Contains(body, "```") || strings.Contains(body, "    ") {
		score += 5
	}
	if regexMatchAny(strings.ToLower(body), `install|setup|getting.started|quick.start`) {
		score += 5
	}
	if score > 30 {
		score = 30
	}
	return score, "readme:" + strconv.Itoa(score) + "/30"
}

var rxSection = regexp.MustCompile(`(?m)^#+\s|^=+$|^-+$`)

func countSections(body string) int {
	return len(rxSection.FindAllString(body, -1))
}

func scoreContributing(dir string) int {
	candidates := []string{
		"CONTRIBUTING.md", "DEVELOPMENT.md",
		"docs/CONTRIBUTING.md", "docs/DEVELOPMENT.md",
		"docs/contributing.md", "docs/development.md",
		".github/CONTRIBUTING.md",
	}
	for _, c := range candidates {
		p := filepath.Join(dir, c)
		if !fileExists(p) {
			continue
		}
		lines := strings.Count(readFile(p), "\n")
		switch {
		case lines > 100:
			return 15
		case lines > 30:
			return 10
		}
		return 5
	}
	return 0
}

func scoreAPI(dir string) int {
	score := 0
	for _, c := range []string{
		"openapi.yaml", "openapi.json", "swagger.yaml", "swagger.json",
		"api/openapi.yaml", "docs/openapi.yaml",
	} {
		if fileExists(filepath.Join(dir, c)) {
			score = 10
			break
		}
	}
	for _, c := range []string{"docs/api", "docs/generated", "site/api", "apidocs"} {
		if dirExists(filepath.Join(dir, c)) {
			score += 5
			break
		}
	}
	if score > 15 {
		score = 15
	}
	return score
}

func scoreArchitecture(dir string) int {
	score := 0
	candidates := []string{
		"ARCHITECTURE.md", "docs/ARCHITECTURE.md", "docs/architecture.md", "docs/design.md",
	}
	if df := os.Getenv("DESIGN_FILE"); df != "" {
		candidates = append(candidates, df)
	}
	for _, c := range candidates {
		p := filepath.Join(dir, c)
		if !fileExists(p) {
			continue
		}
		lines := strings.Count(readFile(p), "\n")
		score = 10
		if lines > 100 {
			score = 15
		}
		if lines > 300 {
			score = 20
		}
		break
	}
	if hasADRDir(dir) {
		score += 5
	}
	if score > 20 {
		score = 20
	}
	return score
}

func hasADRDir(dir string) bool {
	for _, c := range []string{"docs/adr", "docs/ADR", "adr"} {
		full := filepath.Join(dir, c)
		if !dirExists(full) {
			continue
		}
		matches := globMany(full, "*.md")
		if len(matches) > 0 {
			return true
		}
	}
	return false
}

// inlineDocExtensions mirrors bash _assess_inline_docs's grep filter list.
var inlineDocExtensions = map[string]struct{}{
	".py": {}, ".ts": {}, ".js": {}, ".go": {}, ".rs": {},
	".java": {}, ".rb": {}, ".cs": {}, ".kt": {}, ".swift": {},
}

func assessInlineDocs(dir string) int {
	files := sampleSourceFiles(dir, 10)
	if len(files) == 0 {
		return 0
	}
	total := 0
	documented := 0
	rx := regexp.MustCompile(`"""|/\*\*|///|#\s+[A-Z].*\.|// [A-Z].*\.`)
	for _, f := range files {
		full := filepath.Join(dir, f)
		if !fileExists(full) {
			full = f
		}
		if !fileExists(full) {
			continue
		}
		total++
		if rx.MatchString(readFile(full)) {
			documented++
		}
	}
	if total == 0 {
		return 0
	}
	ratio := (documented * 100) / total
	switch {
	case ratio >= 80:
		return 20
	case ratio >= 60:
		return 15
	case ratio >= 40:
		return 10
	case ratio >= 20:
		return 5
	}
	return 0
}

func sampleSourceFiles(dir string, max int) []string {
	var out []string
	for _, p := range listFilesDepth(dir, 3) {
		ext := filepath.Ext(p)
		if _, ok := inlineDocExtensions[ext]; ok {
			out = append(out, p)
		}
		if len(out) >= max {
			break
		}
	}
	return out
}
