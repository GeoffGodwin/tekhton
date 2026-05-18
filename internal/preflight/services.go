package preflight

import (
	"context"
	"fmt"
	"net"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"time"
)

// ServicesCheck ports lib/preflight_services.sh — Docker daemon
// availability, inferred-service port probing, and dev-server detection.
// The inference functions themselves live in services_infer.go.
//
// The check populates Result.ServiceRows which the orchestrator renders
// as a markdown table under "## Services" in PREFLIGHT_REPORT.md.
type ServicesCheck struct{}

// Name returns the canonical check name.
func (ServicesCheck) Name() string { return "services" }

// Run executes the three sub-checks bash ran together when
// preflight_services.sh was sourced.
func (ServicesCheck) Run(_ context.Context, in *Input) Result {
	var r Result
	if f := checkDocker(in); f != nil {
		r.Findings = append(r.Findings, *f)
	}
	svcFindings, svcRows := checkConfiguredServices(in)
	r.Findings = append(r.Findings, svcFindings...)
	r.ServiceRows = append(r.ServiceRows, svcRows...)
	r.Findings = append(r.Findings, checkDevServer(in)...)
	return r
}

// --- Docker daemon -------------------------------------------------------

func checkDocker(in *Input) *Finding {
	proj := in.ProjectDir
	compose := ""
	for _, name := range []string{
		"docker-compose.yml", "docker-compose.yaml",
		"compose.yml", "compose.yaml",
	} {
		if fileExists(proj, name) {
			compose = name
			break
		}
	}
	if compose == "" {
		return nil
	}
	if _, err := exec.LookPath("docker"); err != nil {
		f := warn("Docker", fmt.Sprintf(
			"docker-compose config found (%s) but `docker` is not installed.", compose))
		return &f
	}
	if err := exec.Command("docker", "info").Run(); err == nil {
		f := pass("Docker", "Docker daemon is running.")
		return &f
	}
	f := warn("Docker", `Docker daemon is not running. Start it with: `+
		"`sudo systemctl start docker` or open Docker Desktop.")
	return &f
}

// --- Configured services -------------------------------------------------

// service registry — matches the bash `_PF_SVC_PORTS` and `_PF_SVC_NAMES`
// associative arrays. The display name table is consulted when emitting
// findings/rows; the port table is used by inference helpers in
// services_infer.go.
var svcPorts = map[string]int{
	"postgres":      5432,
	"postgresql":    5432,
	"postgis":       5432,
	"mysql":         3306,
	"mariadb":       3306,
	"mongo":         27017,
	"mongodb":       27017,
	"redis":         6379,
	"rabbitmq":      5672,
	"kafka":         9092,
	"elasticsearch": 9200,
	"opensearch":    9200,
	"minio":         9000,
	"mailhog":       1025,
	"mailpit":       1025,
}

var svcNames = map[string]string{
	"postgres":      "PostgreSQL",
	"postgresql":    "PostgreSQL",
	"postgis":       "PostgreSQL",
	"mysql":         "MySQL",
	"mariadb":       "MariaDB",
	"mongo":         "MongoDB",
	"mongodb":       "MongoDB",
	"redis":         "Redis",
	"rabbitmq":      "RabbitMQ",
	"kafka":         "Kafka",
	"elasticsearch": "Elasticsearch",
	"opensearch":    "OpenSearch",
	"minio":         "MinIO",
	"mailhog":       "Mailhog",
	"mailpit":       "Mailpit",
}

// inferredService is one entry from the inference pass.
type inferredService struct {
	Key         string // canonical key into svcPorts/svcNames
	Source      string // "docker-compose", "package.json", etc.
	HostPort    int    // 0 means "use default"
	DefaultPort int    // bookkeeping for the report
}

// checkConfiguredServices runs the inference pass, probes each inferred
// service's port, and returns findings + populated rows.
func checkConfiguredServices(in *Input) ([]Finding, []ServiceRow) {
	svcs := collectServices(in)
	if len(svcs) == 0 {
		return nil, nil
	}

	isCI := strings.EqualFold(in.Getenv("CI"), "true")
	var findings []Finding
	var rows []ServiceRow

	// Deterministic order by display name.
	sort.SliceStable(svcs, func(i, j int) bool {
		return displayFor(svcs[i].Key) < displayFor(svcs[j].Key)
	})

	for _, s := range svcs {
		display := displayFor(s.Key)
		port := s.HostPort
		if port == 0 {
			port = s.DefaultPort
		}
		row := ServiceRow{
			Display:     display,
			Port:        fmt.Sprintf("%d", port),
			Source:      s.Source,
			DefaultPort: fmt.Sprintf("%d", s.DefaultPort),
		}
		if probeServicePort("127.0.0.1", port, 2*time.Second) {
			row.Status = "running"
			findings = append(findings, pass(fmt.Sprintf("Service (%s)", display),
				fmt.Sprintf("%s is running on port %d.", display, port)))
		} else if isCI {
			row.Status = "not_running"
			findings = append(findings, pass(fmt.Sprintf("Service (%s)", display),
				fmt.Sprintf("%s not detected on port %d (CI environment — may be managed externally).",
					display, port)))
		} else {
			row.Status = "not_running"
			detail := fmt.Sprintf("%s is not running on port %d (detected via %s).",
				display, port, s.Source)
			if instr := buildStartupInstructions(in, display); instr != "" {
				detail += "\nStart it with:\n" + instr
			}
			findings = append(findings, warn(fmt.Sprintf("Service (%s)", display), detail))
		}
		rows = append(rows, row)
	}
	return findings, rows
}

func displayFor(key string) string {
	if v, ok := svcNames[key]; ok {
		return v
	}
	return key
}

// buildStartupInstructions returns OS- and compose-aware suggestions.
func buildStartupInstructions(in *Input, display string) string {
	proj := in.ProjectDir
	var b strings.Builder
	composeFile := ""
	for _, name := range []string{
		"docker-compose.yml", "docker-compose.yaml",
		"compose.yml", "compose.yaml",
	} {
		if fileExists(proj, name) {
			composeFile = name
			break
		}
	}
	svcLower := strings.ToLower(display)
	if composeFile != "" {
		switch {
		case dockerComposeV2Available():
			fmt.Fprintf(&b, "  docker compose up -d %s\n", svcLower)
		case binaryAvailable("docker-compose"):
			fmt.Fprintf(&b, "  docker-compose up -d %s\n", svcLower)
		default:
			fmt.Fprintf(&b, "  docker-compose up -d %s  (%s detected)\n", svcLower, composeFile)
		}
	}
	switch runtime.GOOS {
	case "darwin":
		fmt.Fprintf(&b, "  brew services start %s\n", svcLower)
	case "linux":
		if binaryAvailable("systemctl") {
			fmt.Fprintf(&b, "  sudo systemctl start %s\n", svcLower)
		}
	}
	return b.String()
}

func dockerComposeV2Available() bool {
	if _, err := exec.LookPath("docker"); err != nil {
		return false
	}
	return exec.Command("docker", "compose", "version").Run() == nil
}

func binaryAvailable(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

// probeServicePort attempts a TCP connection to host:port with a hard
// timeout. Mirrors `_probe_service_port` — bash uses /dev/tcp + timeout(1)
// then nc as a fallback; Go's net.DialTimeout collapses both into one call.
func probeServicePort(host string, port int, timeout time.Duration) bool {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, fmt.Sprintf("%d", port)), timeout)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

// --- Dev-server detection ------------------------------------------------

var localhostPortRE = regexp.MustCompile(`localhost:(\d+)`)

func checkDevServer(in *Input) []Finding {
	proj := in.ProjectDir
	port := ""
	source := ""

	for _, name := range []string{
		"playwright.config.ts",
		"playwright.config.js",
		"playwright.config.mjs",
	} {
		p := filepath.Join(proj, name)
		if !fileExists(proj, name) {
			continue
		}
		b, err := readSmall(p)
		if err != nil {
			continue
		}
		if m := localhostPortRE.FindStringSubmatch(string(b)); len(m) == 2 {
			port = m[1]
			source = "playwright.config"
		}
		break
	}
	if port == "" {
		if uiCmd := in.Getenv("UI_TEST_CMD"); uiCmd != "" {
			if m := localhostPortRE.FindStringSubmatch(uiCmd); len(m) == 2 {
				port = m[1]
				source = "UI_TEST_CMD"
			}
		}
	}
	if port == "" {
		return nil
	}

	portNum := 0
	_, _ = fmt.Sscanf(port, "%d", &portNum)
	name := fmt.Sprintf("Dev Server (:%s)", port)
	if probeServicePort("127.0.0.1", portNum, time.Second) {
		return []Finding{pass(name, fmt.Sprintf(
			"Dev server detected (%s) and port %s is responding.", source, port))}
	}
	return []Finding{warn(name, fmt.Sprintf(
		"Dev server expected on port %s (detected via %s) but not running. Many test frameworks handle startup internally.",
		port, source))}
}
