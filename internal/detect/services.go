package detect

import (
	"context"
	"path/filepath"
	"regexp"
	"strings"
)

// ServicesDetector ports lib/detect_services.sh::detect_services —
// docker-compose, Procfile, and Kubernetes manifest service discovery.
type ServicesDetector struct{}

// Name returns the canonical detector name.
func (ServicesDetector) Name() string { return "services" }

// Run executes service discovery.
func (ServicesDetector) Run(_ context.Context, in *Input) (*Result, error) {
	r := &Result{Detector: "services"}
	for _, s := range detectServices(in.ProjectDir) {
		r.Findings = append(r.Findings, map[string]string{
			"name":       s.Name,
			"directory":  s.Directory,
			"tech_stack": s.TechStack,
			"source":     s.Source,
		})
	}
	return r, nil
}

func detectServices(dir string) []Service {
	var out []Service
	out = append(out, detectDockerComposeServices(dir)...)
	out = append(out, detectProcfileServices(dir)...)
	out = append(out, detectK8sServices(dir)...)
	return out
}

var rxComposeService = regexp.MustCompile(`^[[:space:]][[:space:]][a-zA-Z_][a-zA-Z0-9_-]*:`)

func detectDockerComposeServices(dir string) []Service {
	var compose string
	for _, c := range []string{"docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"} {
		if fileExists(filepath.Join(dir, c)) {
			compose = filepath.Join(dir, c)
			break
		}
	}
	if compose == "" {
		return nil
	}
	body := readFile(compose)
	var out []Service
	inServices := false
	var current, build string
	emit := func() {
		if current == "" {
			return
		}
		out = append(out, emitComposeService(dir, current, build))
	}
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "services:") {
			inServices = true
			continue
		}
		if inServices && len(line) > 0 && line[0] != ' ' && line[0] != '\t' && line[0] >= 'a' && line[0] <= 'z' {
			emit()
			current = ""
			build = ""
			inServices = false
			continue
		}
		if !inServices {
			continue
		}
		if rxComposeService.MatchString(line) {
			emit()
			t := strings.TrimLeft(line, " \t")
			if i := strings.IndexByte(t, ':'); i >= 0 {
				current = t[:i]
			}
			build = ""
		}
		if strings.Contains(line, "build:") {
			parts := strings.SplitN(line, "build:", 2)
			if len(parts) == 2 {
				v := strings.TrimSpace(parts[1])
				if v != "." {
					build = v
				}
			}
		}
		if strings.Contains(line, "context:") {
			parts := strings.SplitN(line, "context:", 2)
			if len(parts) == 2 {
				v := strings.Trim(strings.TrimSpace(parts[1]), `"'`)
				if v != "." {
					build = v
				}
			}
		}
	}
	emit()
	return out
}

func emitComposeService(projDir, name, buildDir string) Service {
	bd := strings.TrimPrefix(buildDir, "./")
	if bd == "" {
		bd = "."
	}
	checkDir := projDir
	if bd != "." {
		checkDir = filepath.Join(projDir, bd)
	}
	tech := "unknown"
	if dirExists(checkDir) {
		tech = inferTechFromDir(checkDir)
	}
	return Service{Name: name, Directory: bd, TechStack: tech, Source: "docker-compose"}
}

func detectProcfileServices(dir string) []Service {
	p := filepath.Join(dir, "Procfile")
	if !fileExists(p) {
		return nil
	}
	body := readFile(p)
	var out []Service
	for _, line := range strings.Split(body, "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name := strings.TrimSpace(strings.SplitN(line, ":", 2)[0])
		if name == "" {
			continue
		}
		out = append(out, Service{Name: name, Directory: ".", TechStack: "unknown", Source: "procfile"})
	}
	return out
}

var rxK8sKind = regexp.MustCompile(`^kind:\s*(Deployment|Service|StatefulSet)`)

func detectK8sServices(dir string) []Service {
	var k8sDirs []string
	for _, d := range []string{"k8s", "deploy", "manifests", "charts", "kubernetes", ".k8s"} {
		full := filepath.Join(dir, d)
		if dirExists(full) {
			k8sDirs = append(k8sDirs, full)
		}
	}
	if len(k8sDirs) == 0 {
		return nil
	}
	seen := make(map[string]bool)
	var out []Service
	for _, d := range k8sDirs {
		files := listYAMLDepth(d, 3)
		if len(files) > 50 {
			files = files[:50]
		}
		for _, f := range files {
			svc := parseK8sServiceYAML(dir, f, seen)
			if svc != nil {
				out = append(out, *svc)
			}
		}
	}
	return out
}

func listYAMLDepth(dir string, maxDepth int) []string {
	var out []string
	for _, p := range listFilesDepth(dir, maxDepth) {
		if strings.HasSuffix(p, ".yaml") || strings.HasSuffix(p, ".yml") {
			out = append(out, filepath.Join(dir, p))
		}
	}
	return out
}

func parseK8sServiceYAML(projDir, file string, seen map[string]bool) *Service {
	body := readFile(file)
	if !regexLineMatch(body, `^kind:\s*(Deployment|Service|StatefulSet)`) {
		return nil
	}
	_ = rxK8sKind // keep regex precompiled even though we use line match above

	var name string
	inMeta := false
	for _, line := range strings.Split(body, "\n") {
		t := strings.TrimSpace(line)
		if strings.HasPrefix(t, "metadata:") {
			inMeta = true
			continue
		}
		if inMeta && strings.HasPrefix(t, "name:") {
			parts := strings.Fields(t)
			if len(parts) >= 2 {
				name = strings.Trim(parts[1], `"' `)
			}
			break
		}
	}
	if name == "" {
		return nil
	}
	if seen[name] {
		return nil
	}
	seen[name] = true
	dir := "."
	if dirExists(filepath.Join(projDir, name)) {
		dir = name
	}
	return &Service{Name: name, Directory: dir, TechStack: "unknown", Source: "k8s"}
}

func inferTechFromDir(dir string) string {
	switch {
	case fileExists(filepath.Join(dir, "package.json")):
		if fileExists(filepath.Join(dir, "tsconfig.json")) {
			return "typescript"
		}
		return "node"
	case fileExists(filepath.Join(dir, "pyproject.toml")) || fileExists(filepath.Join(dir, "requirements.txt")):
		return "python"
	case fileExists(filepath.Join(dir, "go.mod")):
		return "go"
	case fileExists(filepath.Join(dir, "Cargo.toml")):
		return "rust"
	case fileExists(filepath.Join(dir, "Gemfile")):
		return "ruby"
	case fileExists(filepath.Join(dir, "pom.xml")) || fileExists(filepath.Join(dir, "build.gradle")):
		return "java"
	case firstMatch(dir, "*.csproj") != "":
		return "csharp"
	}
	return "unknown"
}
