package preflight

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// ServicesInferCheck ports lib/preflight_services_infer.sh — pure
// inference, no probing. It produces no Findings itself; instead the
// inferred service list is consumed by ServicesCheck via collectServices.
// The check still exists in the registry so the order-mismatch test and
// per-check unit tests have something to assert against (the bash side
// kept the inference helpers in a separate file for size; m22 mirrors
// that with a separate Check struct).
type ServicesInferCheck struct{}

// Name returns the canonical check name.
func (ServicesInferCheck) Name() string { return "services_infer" }

// Run is a no-op — inference is invoked synchronously inside
// ServicesCheck.checkConfiguredServices. The empty Result keeps the check
// observable to the orchestrator's per-check timing without producing
// duplicate findings.
func (ServicesInferCheck) Run(_ context.Context, _ *Input) Result {
	return Result{}
}

// readSmall reads a file with an explicit upper bound. Mirrors bash's
// 1 MiB safety cap on config-file reads inside the preflight scanners.
func readSmall(path string) ([]byte, error) {
	const cap = 1 << 20
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(b) > cap {
		return b[:cap], nil
	}
	return b, nil
}

// collectServices is the cross-source inference pass: docker-compose,
// language package manifests, and `.env.example`. Returns a deduplicated
// list of inferredService records ordered by encounter. ServicesCheck
// sorts by display name before probing so report output is deterministic.
func collectServices(in *Input) []inferredService {
	seen := make(map[string]bool)
	var out []inferredService

	add := func(key, source string, hostPort int) {
		if _, ok := svcPorts[key]; !ok {
			return
		}
		display := displayFor(key)
		if seen[display] {
			return
		}
		seen[display] = true
		out = append(out, inferredService{
			Key:         key,
			Source:      source,
			HostPort:    hostPort,
			DefaultPort: svcPorts[key],
		})
	}

	inferFromCompose(in, add)
	inferFromPackages(in, add)
	inferFromEnv(in, add)
	return out
}

// --- docker-compose inference --------------------------------------------

func inferFromCompose(in *Input, add func(key, source string, hostPort int)) {
	proj := in.ProjectDir
	composeFile := ""
	for _, name := range []string{
		"docker-compose.yml", "docker-compose.yaml",
		"compose.yml", "compose.yaml",
	} {
		if fileExists(proj, name) {
			composeFile = filepath.Join(proj, name)
			break
		}
	}
	if composeFile == "" {
		return
	}
	b, err := readSmall(composeFile)
	if err != nil {
		return
	}
	lines := strings.Split(string(b), "\n")

	var currentService, currentImage string
	var currentHostPort int
	inServices := false
	inPorts := false

	flush := func() {
		if currentService == "" {
			return
		}
		key := matchServiceKey(currentImage)
		if key == "" {
			// Fallback: try service name as key.
			if _, ok := svcPorts[strings.ToLower(currentService)]; ok {
				key = strings.ToLower(currentService)
			}
		}
		if key != "" {
			add(key, "docker-compose", currentHostPort)
		}
		currentService = ""
		currentImage = ""
		currentHostPort = 0
		inPorts = false
	}

	for _, line := range lines {
		// Top-level services: marker.
		if strings.HasPrefix(line, "services:") {
			inServices = true
			continue
		}
		// Another top-level key ends the services block.
		if inServices && len(line) > 0 && !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") {
			flush()
			inServices = false
			continue
		}
		if !inServices {
			continue
		}
		// Service name line — exactly two leading spaces (typical compose).
		if isServiceNameLine(line) {
			flush()
			currentService = strings.TrimSuffix(strings.TrimSpace(line), ":")
			continue
		}
		// image: line.
		if idx := strings.Index(line, "image:"); idx >= 0 {
			rest := strings.TrimSpace(line[idx+len("image:"):])
			rest = strings.Trim(rest, "\"'")
			if i := strings.Index(rest, ":"); i >= 0 {
				rest = rest[:i] // strip tag
			}
			if i := strings.LastIndex(rest, "/"); i >= 0 {
				rest = rest[i+1:] // strip registry/namespace
			}
			currentImage = rest
		}
		// ports: section opens.
		if strings.HasPrefix(strings.TrimSpace(line), "ports:") {
			inPorts = true
			continue
		}
		if inPorts {
			trim := strings.TrimSpace(line)
			if strings.HasPrefix(trim, "-") {
				spec := strings.TrimSpace(trim[1:])
				spec = strings.Trim(spec, "\"'")
				spec = strings.ReplaceAll(spec, " ", "")
				if i := strings.Index(spec, ":"); i >= 0 {
					// HOST:CONTAINER
					var n int
					if _, err := parseIntStrict(spec[:i], &n); err == nil {
						currentHostPort = n
					}
				}
			} else {
				inPorts = false
			}
		}
	}
	flush()
}

var serviceNameRE = regexp.MustCompile(`^[\t ]{2}[a-zA-Z_][a-zA-Z0-9_-]*:[\t ]*$`)

func isServiceNameLine(s string) bool {
	return serviceNameRE.MatchString(s)
}

func parseIntStrict(s string, into *int) (int, error) {
	var n int
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0, errBadInt
		}
		n = n*10 + int(r-'0')
	}
	*into = n
	return n, nil
}

// errBadInt sentinels parseIntStrict.
var errBadInt = stringErr("not an int")

type stringErr string

func (e stringErr) Error() string { return string(e) }

// matchServiceKey tries to find a known service key as a substring of the
// image name (case-insensitive).
func matchServiceKey(image string) string {
	if image == "" {
		return ""
	}
	lower := strings.ToLower(image)
	for key := range svcPorts {
		if strings.Contains(lower, key) {
			return key
		}
	}
	return ""
}

// --- Package-manifest inference -------------------------------------------

var (
	jsPostgresRE = regexp.MustCompile(`"(pg|prisma|typeorm|sequelize|knex)"`)
	jsRedisRE    = regexp.MustCompile(`"(redis|ioredis|bull|bullmq)"`)
	jsMongoRE    = regexp.MustCompile(`"(mongoose|mongodb)"`)
	jsRabbitRE   = regexp.MustCompile(`"(amqplib|amqp-connection-manager)"`)
	jsKafkaRE    = regexp.MustCompile(`"kafkajs"`)

	pyPostgresRE = regexp.MustCompile(`(?i)(psycopg2|asyncpg|sqlalchemy|django\.db)`)
	pyRedisRE    = regexp.MustCompile(`(?i)(^|\n)\s*(redis|celery)`)
	pyMongoRE    = regexp.MustCompile(`(?i)(pymongo|mongoengine|motor)`)

	goPostgresRE = regexp.MustCompile(`(pgx|lib/pq)`)
	goRedisRE    = regexp.MustCompile(`go-redis`)
	goMongoRE    = regexp.MustCompile(`mongo-driver`)
)

func inferFromPackages(in *Input, add func(string, string, int)) {
	proj := in.ProjectDir

	if fileExists(proj, "package.json") {
		b, _ := os.ReadFile(filepath.Join(proj, "package.json"))
		s := string(b)
		if jsPostgresRE.MatchString(s) {
			add("postgres", "package.json", 0)
		}
		if jsRedisRE.MatchString(s) {
			add("redis", "package.json", 0)
		}
		if jsMongoRE.MatchString(s) {
			add("mongo", "package.json", 0)
		}
		if jsRabbitRE.MatchString(s) {
			add("rabbitmq", "package.json", 0)
		}
		if jsKafkaRE.MatchString(s) {
			add("kafka", "package.json", 0)
		}
	}

	pyFile := ""
	for _, name := range []string{"requirements.txt", "pyproject.toml", "Pipfile"} {
		if fileExists(proj, name) {
			pyFile = name
			break
		}
	}
	if pyFile != "" {
		b, _ := os.ReadFile(filepath.Join(proj, pyFile))
		s := string(b)
		if pyPostgresRE.MatchString(s) {
			add("postgres", pyFile, 0)
		}
		if pyRedisRE.MatchString(s) {
			add("redis", pyFile, 0)
		}
		if pyMongoRE.MatchString(s) {
			add("mongo", pyFile, 0)
		}
	}

	if fileExists(proj, "go.mod") {
		b, _ := os.ReadFile(filepath.Join(proj, "go.mod"))
		s := string(b)
		if goPostgresRE.MatchString(s) {
			add("postgres", "go.mod", 0)
		}
		if goRedisRE.MatchString(s) {
			add("redis", "go.mod", 0)
		}
		if goMongoRE.MatchString(s) {
			add("mongo", "go.mod", 0)
		}
	}
}

// --- .env-example inference -----------------------------------------------

var (
	envPostgresRE = regexp.MustCompile(`(?im)^(DATABASE_URL|DB_HOST|POSTGRES_)`)
	envRedisRE    = regexp.MustCompile(`(?im)^(REDIS_URL|REDIS_HOST)`)
	envMongoRE    = regexp.MustCompile(`(?im)^(MONGO_URI|MONGODB_URI|MONGO_URL)`)
	envRabbitRE   = regexp.MustCompile(`(?im)^(RABBITMQ_URL|AMQP_URL)`)
)

func inferFromEnv(in *Input, add func(string, string, int)) {
	proj := in.ProjectDir
	envName := ""
	for _, name := range []string{".env.example", ".env.template", ".env.sample"} {
		if fileExists(proj, name) {
			envName = name
			break
		}
	}
	if envName == "" {
		return
	}
	b, _ := os.ReadFile(filepath.Join(proj, envName))
	s := string(b)
	if envPostgresRE.MatchString(s) {
		add("postgres", envName, 0)
	}
	if envRedisRE.MatchString(s) {
		add("redis", envName, 0)
	}
	if envMongoRE.MatchString(s) {
		add("mongo", envName, 0)
	}
	if envRabbitRE.MatchString(s) {
		add("rabbitmq", envName, 0)
	}
}
