package detect

import (
	"path/filepath"
	"strings"
)

// detectUIFramework ports lib/detect.sh::detect_ui_framework — E2E test
// framework detection (playwright/cypress/puppeteer/testing-library/
// detox/selenium) followed by a generic-UI heuristic when no specific
// framework matches. Returns nil when no UI framework can be classified.
//
// The bash function had additional side effects (exporting
// UI_PROJECT_DETECTED and UI_FRAMEWORK in the caller's shell); those
// effects move to the bash wrapper `_tk_detect_ui_framework` in
// lib/common.sh, which reads this row from `tekhton detect summary
// --json` and exports the globals in process.
func detectUIFramework(dir string) *Framework {
	if fw := detectE2EByConfig(dir); fw != nil {
		return fw
	}
	if fw := detectE2EByPackageJSON(dir); fw != nil {
		return fw
	}
	if fw := detectE2EByConvention(dir); fw != nil {
		return fw
	}
	if signalCount := countUISignals(dir); signalCount >= 2 {
		return &Framework{Name: "generic", Language: "web", Evidence: "2+ UI signals detected"}
	}
	return nil
}

func detectE2EByConfig(dir string) *Framework {
	if fileExists(filepath.Join(dir, "playwright.config.ts")) || fileExists(filepath.Join(dir, "playwright.config.js")) {
		return &Framework{Name: "playwright", Language: "node", Evidence: "playwright.config present"}
	}
	return nil
}

func detectE2EByPackageJSON(dir string) *Framework {
	pkg := filepath.Join(dir, "package.json")
	if !fileExists(pkg) {
		return nil
	}
	deps := extractJSONKeys(pkg, `"dependencies"`, `"devDependencies"`)
	switch {
	case strings.Contains(deps, `"@playwright/test"`):
		return &Framework{Name: "playwright", Language: "node", Evidence: `"@playwright/test" in package.json`}
	case strings.Contains(deps, `"cypress"`):
		return &Framework{Name: "cypress", Language: "node", Evidence: `"cypress" in package.json`}
	case strings.Contains(deps, `"puppeteer"`):
		return &Framework{Name: "puppeteer", Language: "node", Evidence: `"puppeteer" in package.json`}
	}
	if strings.Contains(deps, `"@testing-library/react"`) ||
		strings.Contains(deps, `"@testing-library/vue"`) ||
		strings.Contains(deps, `"@testing-library/svelte"`) {
		return &Framework{Name: "testing-library", Language: "node", Evidence: "@testing-library/* in package.json"}
	}
	if strings.Contains(deps, `"detox"`) {
		return &Framework{Name: "detox", Language: "node", Evidence: `"detox" in package.json`}
	}
	return nil
}

func detectE2EByConvention(dir string) *Framework {
	if fileExists(filepath.Join(dir, "cypress.config.ts")) ||
		fileExists(filepath.Join(dir, "cypress.config.js")) ||
		dirExists(filepath.Join(dir, "cypress")) {
		return &Framework{Name: "cypress", Language: "node", Evidence: "cypress config or cypress/ directory"}
	}
	if fileExists(filepath.Join(dir, "requirements.txt")) {
		if strings.Contains(strings.ToLower(readFile(filepath.Join(dir, "requirements.txt"))), "selenium") {
			return &Framework{Name: "selenium", Language: "python", Evidence: "selenium in requirements.txt"}
		}
	}
	if fileExists(filepath.Join(dir, "pom.xml")) {
		if strings.Contains(readFile(filepath.Join(dir, "pom.xml")), "selenium") {
			return &Framework{Name: "selenium", Language: "java", Evidence: "selenium in pom.xml"}
		}
	}
	if fileExists(filepath.Join(dir, ".detoxrc.js")) || fileExists(filepath.Join(dir, ".detoxrc.json")) {
		return &Framework{Name: "detox", Language: "node", Evidence: ".detoxrc config present"}
	}
	return nil
}

func countUISignals(dir string) int {
	count := 0
	if hasSourceFiles(dir, "tsx", "jsx") {
		count++
	}
	if hasSourceFiles(dir, "vue", "svelte") {
		count++
	}
	for _, d := range []string{"templates", "app/views", "src/pages", "pages"} {
		if dirExists(filepath.Join(dir, d)) {
			count++
			break
		}
	}
	if fileExists(filepath.Join(dir, "package.json")) {
		deps := extractJSONKeys(filepath.Join(dir, "package.json"), `"dependencies"`)
		if strings.Contains(deps, `"react"`) ||
			strings.Contains(deps, `"vue"`) ||
			strings.Contains(deps, `"svelte"`) ||
			strings.Contains(deps, `"@angular/core"`) {
			count++
		}
	}
	if hasSourceFiles(dir, "scss") || hasSourceFiles(dir, "css") {
		count++
	}
	if dirExists(filepath.Join(dir, "templates")) && fileExists(filepath.Join(dir, "manage.py")) {
		count++
	}
	if dirExists(filepath.Join(dir, "app/views")) && fileExists(filepath.Join(dir, "Gemfile")) {
		count++
	}
	return count
}
