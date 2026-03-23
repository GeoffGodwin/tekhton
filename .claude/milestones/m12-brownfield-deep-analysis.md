#### Milestone 12: Brownfield Deep Analysis & Inference Quality
Upgrade the detection and crawling heuristics to handle complex project structures:
monorepos with workspaces, multi-service repositories, CI/CD-informed inference,
existing documentation quality assessment, and smarter config generation that
accounts for project maturity and complexity.

This milestone makes `--init` produce accurate results for the hardest cases —
large brownfield codebases with years of accumulated structure, multiple build
systems, and inconsistent conventions.

Files to modify:
- `lib/detect.sh` — Expand language detection with:
  **Monorepo / workspace detection:**
  - Detect workspace roots: pnpm-workspace.yaml, lerna.json, nx.json,
    package.json "workspaces" field, Cargo workspace [workspace] in
    Cargo.toml, Go workspace go.work files, Gradle multi-project
    (settings.gradle with include), Maven multi-module (pom.xml with modules).
  - When workspace detected, enumerate sub-projects and detect per-project.
    Output includes workspace root + per-project language/framework.
  - New function: `detect_workspaces($project_dir)` returns
    `WORKSPACE_TYPE|ROOT_MANIFEST|SUBPROJECT_PATHS`.
  **Infrastructure-as-code detection:**
  - Detect Terraform (.tf files, terraform/ directory, .terraform.lock.hcl)
  - Detect Pulumi (Pulumi.yaml, Pulumi.*.yaml)
  - Detect AWS CDK (cdk.json, cdk.out/)
  - Detect CloudFormation (template.yaml/json with AWSTemplateFormatVersion)
  - Detect Ansible (playbooks/, ansible.cfg, inventory/)
  - New function: `detect_infrastructure($project_dir)` returns
    `IAC_TOOL|PATH|PROVIDER|CONFIDENCE`. Feeds into security agent context
    (infrastructure misconfigs are a major vulnerability class).
  **Multi-service detection:**
  - Detect docker-compose.yml / docker-compose.yaml with multiple services.
  - Detect Procfile with multiple process types.
  - Detect Kubernetes manifests (k8s/, deploy/, manifests/) referencing
    multiple service names.
  - Cross-reference service names with directory structure to map
    service → directory → tech stack.
  - New function: `detect_services($project_dir)` returns
    `SERVICE_NAME|DIRECTORY|TECH_STACK|SOURCE` (source = docker-compose,
    procfile, k8s, directory-convention).
  **CI/CD-informed inference:**
  - Parse .github/workflows/*.yml for: build commands, test commands,
    language setup actions (actions/setup-node, actions/setup-python, etc.),
    environment variables hinting at services, deployment targets.
  - Parse .gitlab-ci.yml, Jenkinsfile, .circleci/config.yml,
    bitbucket-pipelines.yml for similar signals.
  - Parse Dockerfile / Dockerfile.* for base images (node:18, python:3.11)
    confirming language versions.
  - CI-detected commands used to validate/override heuristic command detection.
    CI has higher confidence than manifest heuristics because it's what
    actually runs in production.
  - New function: `detect_ci_config($project_dir)` returns
    `CI_SYSTEM|BUILD_CMD|TEST_CMD|LINT_CMD|DEPLOY_TARGET|CONFIDENCE`.

- `lib/detect_commands.sh` — Enhanced command inference:
  **Priority cascade:**
  1. CI/CD config (highest confidence — this is what actually runs)
  2. Makefile / Taskfile / justfile targets
  3. Package manager scripts (package.json, pyproject.toml)
  4. Convention-based fallback (current behavior, lowest confidence)
  When multiple sources agree, confidence = high.
  When sources disagree, flag for user confirmation during init.
  **Additional detection:**
  - Detect linters: eslint, prettier, ruff, black, clippy, golangci-lint
    from config files (.eslintrc*, pyproject.toml [tool.ruff], etc.)
  - Detect formatters separate from linters.
  - Detect pre-commit hooks (.pre-commit-config.yaml) as an authoritative
    source for lint/format commands.
  **Test framework detection (separate from TEST_CMD):**
  - Detect specific frameworks: pytest, unittest, jest, vitest, mocha,
    cypress, playwright, go test, cargo test, rspec, minitest, junit, xunit.
  - Source: config files (jest.config.*, pytest.ini, vitest.config.*),
    dependency manifests, test file naming conventions (*_test.go, *.spec.ts).
  - New function: `detect_test_frameworks($project_dir)` returns
    `FRAMEWORK|CONFIG_FILE|CONFIDENCE`. Injected into tester agent context
    so it generates framework-appropriate test code.

- `lib/detect_report.sh` — Enhanced report format:
  - Add workspace section when workspaces detected.
  - Add services section when multi-service detected.
  - Add CI/CD section with detected pipeline config.
  - Add documentation quality section (see below).
  - Color-code confidence levels in terminal output.
  - Show source attribution for each detection ("detected from: CI workflow").

- `lib/crawler.sh` — Smarter crawl budget allocation for complex projects:
  - When workspaces detected, allocate per-subproject budgets proportional
    to file count. Ensure each subproject gets at least a minimum sample.
  - When services detected, prioritize sampling from service entry points
    and shared libraries.
  - Add documentation quality assessment to crawl phase:
    New function: `_assess_doc_quality($project_dir)` evaluates:
    - README.md: exists? length? has sections? has examples?
    - CONTRIBUTING.md / DEVELOPMENT.md: setup instructions present?
    - API docs: OpenAPI/Swagger specs, generated docs directories?
    - Architecture docs: ARCHITECTURE.md, docs/architecture/, ADRs?
    - Inline doc density: sample ratio of documented vs undocumented exports
    Score: 0-100 doc quality score. Used by synthesis to calibrate how much
    it should trust existing docs vs infer from code.
  - Add `DOC_QUALITY_SCORE` to PROJECT_INDEX.md metadata.

- `lib/init.sh` — Updated routing and config generation:
  - When workspaces detected, ask user: "This is a monorepo with N
    subprojects. Should Tekhton manage the root (all projects) or a
    specific subproject?" Offer list of detected subprojects.
  - When services detected, include service map in pipeline.conf comments
    so the user can configure per-service overrides if needed.
  - When CI/CD detected, pre-populate TEST_CMD, ANALYZE_CMD, BUILD_CHECK_CMD
    from CI config with high confidence (VERIFY markers only when CI and
    heuristic disagree).
  - Adjust `_emit_models()` in init_config.sh: consider doc quality score.
    Low doc quality + large project → use opus for coder (needs more
    reasoning about unclear architecture). High doc quality → sonnet
    sufficient.

- `lib/init_config.sh` — Add workspace and service awareness:
  - New `_emit_workspace_config()` section when workspaces detected.
  - Include detected CI commands with source annotations.
  - Add `PROJECT_STRUCTURE=monorepo|multi-service|single` config key.
  - Add `WORKSPACE_TYPE` and `WORKSPACE_SUBPROJECTS` config keys
    for monorepo awareness.

- `lib/config_defaults.sh` — Add:
  DETECT_WORKSPACES_ENABLED=true,
  DETECT_SERVICES_ENABLED=true,
  DETECT_CI_ENABLED=true,
  DOC_QUALITY_ASSESSMENT_ENABLED=true,
  PROJECT_STRUCTURE=single (overridden by detection).

- `stages/init_synthesize.sh` — Update synthesis context assembly:
  - Include workspace structure in synthesis context when detected.
  - Include service map in synthesis context when detected.
  - Include doc quality score so synthesis agent calibrates depth
    of inference vs reliance on existing documentation.
  - When doc quality is high (>70), instruct agent to extract and
    preserve existing architectural decisions rather than inferring new ones.
  - When doc quality is low (<30), instruct agent to infer more
    aggressively from code patterns and generate more detailed
    architecture documentation.

Acceptance criteria:
- `detect_workspaces()` correctly identifies: npm/yarn/pnpm workspaces,
  lerna, nx, Cargo workspaces, Go workspaces, Gradle multi-project,
  Maven multi-module
- `detect_services()` identifies services from docker-compose, Procfile,
  and k8s manifests, mapping them to directories and tech stacks
- `detect_ci_config()` parses GitHub Actions, GitLab CI, CircleCI,
  Jenkinsfile, and Bitbucket Pipelines for build/test/lint commands
- CI-detected commands take precedence over heuristic detection
- When multiple detection sources disagree, user is prompted to confirm
- Monorepo init asks user to choose root vs subproject scope
- Doc quality assessment produces a 0-100 score from README, contributing
  guides, API docs, architecture docs, and inline doc density
- DOC_QUALITY_SCORE included in PROJECT_INDEX.md metadata
- Synthesis agent adjusts inference depth based on doc quality score
- Crawler budget allocation adapts for workspaces (per-subproject budgets)
- Detection report includes workspace, service, CI, and doc quality sections
- `detect_infrastructure()` identifies Terraform, Pulumi, CDK, CloudFormation,
  Ansible with provider attribution
- `detect_test_frameworks()` identifies specific test frameworks (not just TEST_CMD)
  and is injected into tester agent context
- All detections include source attribution and confidence level
- Single-project repos see zero change in behavior (backward compatible)
- All existing tests pass
- `bash -n` passes on all modified files
- `shellcheck` passes on all modified files
- New test cases cover: monorepo detection, service detection, CI parsing,
  doc quality assessment, workspace-aware crawling

Watch For:
- Monorepo workspace enumeration can be expensive for repos with many
  subprojects (100+ packages in a lerna monorepo). Cap enumeration at
  a configurable limit (default 50 subprojects) and summarize the rest.
- CI/CD parsing must be read-only and safe. Never execute CI commands,
  only read config files. Some CI configs reference secrets and sensitive
  values — skip those fields entirely.
- docker-compose.yml parsing with awk/sed is fragile for complex YAML.
  Focus on the `services:` top-level key and extract service names +
  build context paths. Don't try to parse the full YAML spec.
- The doc quality score is a heuristic, not a precise metric. It's used
  to tune synthesis behavior, not as a gate. Don't over-engineer it.
- Go workspaces (go.work) are relatively new. Ensure the detection
  handles repos that have go.mod but NOT go.work (single module, not
  workspace).
- Kubernetes manifest detection should only scan for standard deployment/
  service YAMLs, not every .yaml file in the repo. Look in conventional
  directories (k8s/, deploy/, manifests/, charts/) first.
- Jenkinsfile parsing is hard (Groovy DSL with arbitrary code). Only detect
  obvious `pipeline { stages { ... } }` patterns and mark confidence as low.
  Don't try to eval Groovy.
- Terraform state files (.tfstate) must NEVER be read — they can contain
  secrets. Only read .tf config files.
- Test framework detection is separate from test command detection. The tester
  agent needs to know "use pytest" vs "use unittest" even when TEST_CMD is
  just "make test".

Seeds Forward:
- Workspace and service detection feeds into V4 environment awareness
  (which services talk to which APIs)
- CI command detection is reusable by the security agent (what security
  scanning is already in the CI pipeline?)
- Doc quality score feeds into the PM agent's confidence calibration
  (low doc quality + vague task = more likely NEEDS_CLARITY)
- Multi-service detection feeds into future parallel execution
  (different services could be milestoned independently)
- The monorepo "choose subproject" flow seeds the Dashboard UI's
  project selector concept
