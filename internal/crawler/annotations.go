// Package crawler is the Go-side project crawler that produces the
// .claude/index/ artifact set consumed by init, scout, and downstream
// agents. m30.1 ports the six bash files under lib/crawler*.sh.
//
// The package is intentionally read-only on the project tree and
// write-only on the configured index directory. The crawler MUST NOT
// mutate any path outside Options.IndexDir.
package crawler

import "path"

// annotatePackage maps a well-known package / crate / gem name to a short
// purpose hint. Ports lib/crawler_deps.sh::_annotate_package verbatim —
// arm order, glob coverage, and the literal "echo" arm are preserved.
//
// Returns "" when no annotation is known; callers render that as an
// empty Purpose column in the dependency tables.
func annotatePackage(pkg string) string {
	if p, ok := packagePurposes[pkg]; ok {
		return p
	}
	for _, entry := range packagePurposeGlobs {
		if matched, _ := path.Match(entry.pattern, pkg); matched {
			return entry.purpose
		}
	}
	return ""
}

// packagePurposes is the literal-match arm of the bash case statement.
// Patterns containing glob metacharacters (`*`, `?`) live in
// packagePurposeGlobs and are matched by path.Match.
//
// The "echo" entry is intentional — the bash case has an `echo)` arm
// that handles the Go echo HTTP router. Do NOT remove it on the
// assumption it is a typo.
var packagePurposes = map[string]string{
	// Web frameworks (Node / Python / Rust / Go)
	"express": "Web framework", "koa": "Web framework", "hapi": "Web framework",
	"fastify": "Web framework", "django": "Web framework", "flask": "Web framework",
	"fastapi": "Web framework", "starlette": "Web framework", "actix-web": "Web framework",
	"axum": "Web framework", "warp": "Web framework", "rocket": "Web framework",
	"gin": "Web framework", "fiber": "Web framework", "chi": "Web framework",

	// Frontend frameworks
	"react": "Frontend framework", "preact": "Frontend framework",
	"vue": "Frontend framework", "svelte": "Frontend framework",

	// Full-stack frameworks
	"next": "Full-stack framework", "nuxt": "Full-stack framework",
	"gatsby": "Full-stack framework", "rails": "Full-stack framework",

	// Compilers / type systems
	"typescript": "TypeScript compiler",

	// Build tools
	"webpack": "Build tool / bundler", "vite": "Build tool / bundler",
	"rollup": "Build tool / bundler", "esbuild": "Build tool / bundler",
	"parcel": "Build tool / bundler",

	// Test frameworks
	"jest": "Test framework", "vitest": "Test framework", "mocha": "Test framework",
	"ava": "Test framework", "tap": "Test framework", "pytest": "Test framework",
	"unittest": "Test framework", "nose2": "Test framework", "rspec": "Test framework",

	// Linters / formatters
	"eslint": "Linter / formatter", "prettier": "Linter / formatter",
	"rome": "Linter / formatter", "biome": "Linter / formatter",

	// HTTP clients
	"axios": "HTTP client", "node-fetch": "HTTP client", "got": "HTTP client",
	"superagent": "HTTP client", "requests": "HTTP client", "httpx": "HTTP client",
	"aiohttp": "HTTP client",

	// Utility libraries
	"lodash": "Utility library", "underscore": "Utility library", "ramda": "Utility library",

	// ORMs / databases
	"mongoose": "ORM / database", "sequelize": "ORM / database",
	"prisma": "ORM / database", "typeorm": "ORM / database",
	"sqlalchemy": "ORM / database", "gorm": "ORM / database",

	// Database drivers
	"redis": "Database driver", "ioredis": "Database driver", "pg": "Database driver",
	"mysql2": "Database driver", "sqlite3": "Database driver",
	"better-sqlite3": "Database driver",

	// Scientific computing
	"numpy": "Scientific computing", "pandas": "Scientific computing",
	"scipy": "Scientific computing",

	// Data validation / task queues
	"pydantic": "Data validation",
	"celery":   "Task queue",

	// Core Rust libraries
	"serde": "Core Rust library", "tokio": "Core Rust library",
	"reqwest": "Core Rust library",

	// CLI argument parsers
	"clap": "CLI argument parser", "structopt": "CLI argument parser",

	// Go HTTP router (bash arm: `echo)` — preserve literally)
	"echo": "HTTP router",
}

// packagePurposeGlobs holds the glob-pattern arms of the bash case
// statement. Order mirrors the bash source: the catch-all `*)` arm
// (which returns "") is the absence of a match.
var packagePurposeGlobs = []struct {
	pattern string
	purpose string
}{
	{pattern: "angular*", purpose: "Frontend framework"},
	{pattern: "@angular/*", purpose: "Frontend framework"},
	{pattern: "drizzle*", purpose: "ORM / database"},
	{pattern: "spring-boot*", purpose: "Application framework"},
}
