package detect

import (
	"path/filepath"
	"regexp"
	"strings"
)

// packageJSONCommands ports the package.json branch of _detect_package_commands.
func packageJSONCommands(dir string) []Command {
	p := filepath.Join(dir, "package.json")
	if !fileExists(p) {
		return nil
	}
	scripts := extractJSONKeys(p, `"scripts"`)
	var out []Command

	if test := pkgScriptValue(scripts, "test"); test != "" && !strings.Contains(test, "no test specified") {
		out = append(out, Command{Type: "test", Command: "npm test", Source: "package.json scripts.test", Confidence: "high"})
	}

	if pkgScriptHasKey(scripts, "lint") {
		out = append(out, Command{Type: "analyze", Command: "npm run lint", Source: "package.json scripts.lint", Confidence: "high"})
	} else {
		eslintBin := filepath.Join(dir, "node_modules", ".bin", "eslint")
		if fileExists(eslintBin) {
			out = append(out, Command{Type: "analyze", Command: "npx eslint .", Source: "node_modules/.bin/eslint exists", Confidence: "medium"})
		}
	}

	if pkgScriptHasKey(scripts, "build") {
		out = append(out, Command{Type: "build", Command: "npm run build", Source: "package.json scripts.build", Confidence: "high"})
	}
	return out
}

// pkgScriptValue mirrors the bash `grep '"NAME"' | sed 's/.*: *"\(.*\)".*/\1/'`
// extractor — returns the FIRST script's value matching name, or "".
func pkgScriptValue(scripts, name string) string {
	needle := `"` + name + `"`
	rx := regexp.MustCompile(`.*: *"(.*)".*`)
	for _, line := range strings.Split(scripts, "\n") {
		if !strings.Contains(line, needle) {
			continue
		}
		m := rx.FindStringSubmatch(line)
		if m == nil {
			return ""
		}
		return m[1]
	}
	return ""
}

func pkgScriptHasKey(scripts, name string) bool {
	return strings.Contains(scripts, `"`+name+`"`)
}

// pythonCommands ports the python branch.
func pythonCommands(dir string) []Command {
	py := filepath.Join(dir, "pyproject.toml")
	if fileExists(py) {
		body := readFile(py)
		var out []Command
		if regexLineMatch(body, `\[tool\.pytest`) {
			out = append(out, Command{Type: "test", Command: "pytest", Source: "pyproject.toml [tool.pytest]", Confidence: "high"})
		} else {
			out = append(out, Command{Type: "test", Command: "pytest", Source: "pyproject.toml present", Confidence: "medium"})
		}
		switch {
		case regexLineMatch(body, `\[tool\.ruff`):
			out = append(out, Command{Type: "analyze", Command: "ruff check .", Source: "pyproject.toml [tool.ruff]", Confidence: "high"})
		case regexLineMatch(body, `\[tool\.flake8`):
			out = append(out, Command{Type: "analyze", Command: "flake8 .", Source: "pyproject.toml [tool.flake8]", Confidence: "high"})
		default:
			out = append(out, Command{Type: "analyze", Command: "ruff check .", Source: "convention", Confidence: "low"})
		}
		return out
	}
	if fileExists(filepath.Join(dir, "requirements.txt")) || fileExists(filepath.Join(dir, "setup.py")) {
		return []Command{
			{Type: "test", Command: "pytest", Source: "Python project detected", Confidence: "medium"},
			{Type: "analyze", Command: "ruff check .", Source: "convention", Confidence: "low"},
		}
	}
	return nil
}

// gemfileCommands ports the Gemfile branch.
func gemfileCommands(dir string) []Command {
	gem := filepath.Join(dir, "Gemfile")
	if !fileExists(gem) {
		return nil
	}
	body := readFile(gem)
	var out []Command
	switch {
	case strings.Contains(body, "rspec"):
		out = append(out, Command{Type: "test", Command: "bundle exec rspec", Source: "rspec in Gemfile", Confidence: "high"})
	case strings.Contains(body, "minitest"):
		out = append(out, Command{Type: "test", Command: "bundle exec rake test", Source: "minitest in Gemfile", Confidence: "high"})
	}
	if strings.Contains(body, "rubocop") {
		out = append(out, Command{Type: "analyze", Command: "bundle exec rubocop", Source: "rubocop in Gemfile", Confidence: "high"})
	}
	return out
}

// gradleMavenCommands ports the Java/Kotlin branch.
func gradleMavenCommands(dir string) []Command {
	if fileExists(filepath.Join(dir, "build.gradle")) || fileExists(filepath.Join(dir, "build.gradle.kts")) {
		return []Command{
			{Type: "test", Command: "./gradlew test", Source: "build.gradle present", Confidence: "high"},
			{Type: "build", Command: "./gradlew build", Source: "build.gradle present", Confidence: "high"},
		}
	}
	if fileExists(filepath.Join(dir, "pom.xml")) {
		return []Command{
			{Type: "test", Command: "mvn test", Source: "pom.xml present", Confidence: "high"},
			{Type: "build", Command: "mvn package", Source: "pom.xml present", Confidence: "high"},
		}
	}
	return nil
}

// pubspecCommands ports the Dart/Flutter branch.
func pubspecCommands(dir string) []Command {
	p := filepath.Join(dir, "pubspec.yaml")
	if !fileExists(p) {
		return nil
	}
	if strings.Contains(readFile(p), "flutter:") {
		return []Command{
			{Type: "test", Command: "flutter test", Source: "flutter in pubspec.yaml", Confidence: "high"},
			{Type: "build", Command: "flutter build", Source: "flutter in pubspec.yaml", Confidence: "high"},
			{Type: "analyze", Command: "flutter analyze", Source: "flutter in pubspec.yaml", Confidence: "high"},
		}
	}
	return []Command{
		{Type: "test", Command: "dart test", Source: "pubspec.yaml present", Confidence: "high"},
		{Type: "analyze", Command: "dart analyze", Source: "pubspec.yaml present", Confidence: "high"},
	}
}
