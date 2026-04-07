
#### Milestone 18: Documentation Site (MkDocs + GitHub Pages)
<!-- milestone-meta
id: "18"
status: "done"
-->
<!-- PM-tweaked: 2026-03-24 -->

Create a comprehensive documentation site using MkDocs with Material theme,
deployed via GitHub Pages. Covers: Getting Started guide, command reference,
configuration guide, concepts explainer, and troubleshooting. Auto-deploys
on push to main via GitHub Actions.

The docs site is Tekhton's public face — the thing a potential user reads before
deciding to try it. It must answer: "What is this?", "How do I install it?",
"How do I use it?", and "What do I do when something breaks?" in that order.

The documentation source lives in the Tekhton repo alongside the code. This
ensures docs update atomically with features. MkDocs builds static HTML that
deploys to GitHub Pages independently of the owner's blog (geoffgodwin.com).

Files to create:
- `mkdocs.yml` — MkDocs configuration:
  ```yaml
  site_name: Tekhton
  site_description: Multi-agent development pipeline built on Claude
  site_url: https://geoffgodwin.github.io/tekhton/  # or custom domain
  repo_url: https://github.com/geoffgodwin/tekhton
  repo_name: geoffgodwin/tekhton

  theme:
    name: material
    palette:
      - scheme: slate         # Dark theme default (matches Watchtower)
        primary: deep purple
        accent: amber
        toggle:
          icon: material/brightness-7
          name: Switch to light mode
      - scheme: default
        primary: deep purple
        accent: amber
        toggle:
          icon: material/brightness-4
          name: Switch to dark mode
    features:
      - navigation.tabs
      - navigation.sections
      - navigation.expand
      - navigation.top
      - search.suggest
      - search.highlight
      - content.code.copy
      - content.tabs.link

  nav:
    - Home: index.md
    - Getting Started:
      - Installation: getting-started/installation.md
      - Your First Project: getting-started/first-project.md
      - Your First Milestone: getting-started/first-milestone.md
      - Understanding Output: getting-started/understanding-output.md
    - Guides:
      - Greenfield Projects: guides/greenfield.md
      - Brownfield Projects: guides/brownfield.md
      - Monorepo Setup: guides/monorepo.md
      - Security Configuration: guides/security-config.md
      - Watchtower Dashboard: guides/watchtower.md
      - Planning Phase: guides/planning.md
    - Reference:
      - Commands: reference/commands.md
      - Configuration: reference/configuration.md
      - Pipeline Stages: reference/stages.md
      - Agent Roles: reference/agents.md
      - Template Variables: reference/template-variables.md
    - Concepts:
      - Pipeline Flow: concepts/pipeline-flow.md
      - Milestone DAG: concepts/milestone-dag.md
      - Health Scoring: concepts/health-scoring.md
      - Context Budget: concepts/context-budget.md
    - Troubleshooting:
      - Using --diagnose: troubleshooting/diagnose.md
      - Common Errors: troubleshooting/common-errors.md
      - FAQ: troubleshooting/faq.md
    - Changelog: changelog.md

  markdown_extensions:
    - admonition
    - pymdownx.details
    - pymdownx.superfences
    - pymdownx.tabbed
    - pymdownx.highlight
    - pymdownx.inlinehilite
    - attr_list
    - md_in_html
    - toc:
        permalink: true
  ```

- `docs/requirements.txt` — MkDocs dependencies (separate from tools/requirements.txt):
  ```
  mkdocs-material>=9.0
  ```

- `docs/index.md` — Landing page:
  - Hero: "One intent. Many hands." tagline + one-paragraph description
  - Quick start: 3-command install + init + run example
  - Feature highlights: Security agent, PM agent, Watchtower, Health scoring
  - "Who is this for?" section addressing both experienced devs and newcomers
  - Link to Getting Started for the full walkthrough

- `docs/getting-started/installation.md` — Install guide:
  - Prerequisites: bash 4+, Claude CLI installed and authenticated
  - Quick install (one-liner curl script from M19)
  - Manual install (git clone for contributors)
  - Platform notes:
    - **macOS:** bash 4+ via Homebrew (`brew install bash`), explain macOS ships
      bash 3.2 and why that matters
    - **Linux:** usually fine out of the box, note Ubuntu/Debian bash 4+ is default
    - **Windows:** WSL required (link to WSL install guide). Explain that Tekhton
      is bash-native and WSL provides the environment. Git Bash is NOT sufficient
      (lacks bash 4 features).
  - Verify installation: `tekhton --version`
  - Optional dependencies: Python 3.8+ (for repo map indexer), tree-sitter

- `docs/getting-started/first-project.md` — End-to-end walkthrough:
  - Start with a fresh project directory
  - Run `tekhton --init`
  - Walk through what --init produces: pipeline.conf, agent roles, CLAUDE.md,
    milestones, Watchtower dashboard
  - Explain each file briefly with "you'll customize this later" notes
  - End with "open the Watchtower to see your project: open .claude/dashboard/index.html"

- `docs/getting-started/first-milestone.md` — Running the first pipeline:
  - `tekhton --milestone`
  - Explain what happens at each stage (scout → coder → security → reviewer → tester)
  - Show what the terminal output means
  - Point to Watchtower for a visual view
  - What to do when it finishes (check the commit, review changes)
  - What to do when it fails (use --diagnose)

- `docs/getting-started/understanding-output.md` — Reading Tekhton's artifacts:
  - CODER_SUMMARY.md, REVIEWER_REPORT.md, SECURITY_REPORT.md explained
  - RUN_SUMMARY.json fields explained
  - HEALTH_REPORT.md explained
  - How to read the Watchtower dashboard tabs

- `docs/guides/brownfield.md` — Brownfield-specific guide:
  - What --init does differently for existing codebases
  - AI artifact detection and handling options
  - Health baseline and what the score means
  - How to customize pipeline.conf for your existing build/test commands
  - Monorepo considerations (link to monorepo guide)

- `docs/guides/greenfield.md` — Starting a project from scratch:
  - Using --plan to design your project
  - How the interview phase works
  - Reviewing generated DESIGN.md and CLAUDE.md
  - Customizing milestones before running

- `docs/guides/security-config.md` — Security agent configuration:
  - Understanding severity levels
  - Configuring SECURITY_UNFIXABLE_POLICY
  - Setting up waivers (SECURITY_WAIVER_FILE)
  - Online vs offline mode
  - Reading SECURITY_REPORT.md

- `docs/guides/watchtower.md` — Watchtower dashboard guide:
  - How to open it
  - Tour of each tab with screenshots (placeholder `<!-- TODO: screenshot -->` comments acceptable for initial merge; regenerate when Watchtower UI stabilizes)
  - Troubleshooting (Safari file:// restrictions, etc.)
  - Verbosity levels

- `docs/reference/commands.md` — Complete command reference:
  - Every flag and option with examples
  - --init, --plan, --milestone, --complete, --auto-advance, --diagnose,
    --health, --resume, --start-at, --skip-security, --human, --replan, --docs, etc.

- `docs/reference/configuration.md` — Complete pipeline.conf reference:
  - Every config key, default value, valid range, and explanation
  - Organized by section (core, security, intake, health, watchtower, etc.)
  - Example configurations for common setups

- `docs/reference/stages.md` — Pipeline stage reference:
  - What each stage does, its inputs and outputs
  - Turn budgets and how to tune them
  - How rework loops work

- `docs/reference/agents.md` — Agent role file reference:
  - How to customize agent roles
  - What each default role contains
  - How to write effective role definitions

- `docs/concepts/pipeline-flow.md` — Architecture explainer:
  - Full pipeline flow diagram
  - How stages interact
  - How the context budget system works
  - How the milestone DAG drives execution

- `docs/troubleshooting/diagnose.md` — --diagnose guide:
  - What each diagnostic rule means
  - Recovery steps for each failure type
  - When to ask for help vs self-service

- `docs/troubleshooting/faq.md` — Frequently asked questions:
  - "How much does it cost to run?" (quota/token estimation)
  - "Can I use it with GPT/Gemini?" (no — Claude CLI only)
  - "Can multiple people use it on the same repo?" (not yet — V4)
  - "How do I undo what Tekhton did?" (git revert the commit)
  - "Is it safe to run on production code?" (yes, explain safety model)

- `docs/changelog.md` — Version history:
  - Auto-generated or manually maintained
  - One section per minor version (3.7, 3.8, etc.)
  - Links to milestone specs for details

- `.github/workflows/docs.yml` — GitHub Actions workflow:

  [PM: The original workflow was missing the `actions/upload-pages-artifact` step required before `actions/deploy-pages@v4`. Without it, the deploy step has no artifact to publish and the workflow fails. Fixed below:]

  ```yaml
  name: Deploy Docs
  on:
    push:
      branches: [main]
      paths: ['docs/**', 'mkdocs.yml']
  permissions:
    contents: read
    pages: write
    id-token: write
  jobs:
    deploy:
      runs-on: ubuntu-latest
      environment:
        name: github-pages
        url: ${{ steps.deployment.outputs.page_url }}
      steps:
        - uses: actions/checkout@v4
        - uses: actions/setup-python@v5
          with:
            python-version: '3.x'
        - run: pip install -r docs/requirements.txt
        - run: mkdocs build
        - uses: actions/upload-pages-artifact@v3
          with:
            path: site/
        - id: deployment
          uses: actions/deploy-pages@v4
  ```
  Deploys only when docs/ or mkdocs.yml change. Zero manual intervention.
  Note: GitHub Pages must be enabled in the repo Settings → Pages → Source: GitHub Actions.

Files to modify:
- `.gitignore` — Add `site/` (MkDocs build output directory).
- `tekhton.sh` — Add `--docs` flag that opens the documentation URL in the
  default browser (`xdg-open` / `open` / `start` depending on platform).
  Also prints the URL for copy-paste.

  [PM: Clarified behavior: `--docs` opens the remote GitHub Pages URL (the
  `site_url` from mkdocs.yml), not a local mkdocs serve URL. This works
  regardless of whether mkdocs is installed locally. Print the URL to stdout
  before attempting to open, so it's always visible even if the browser open fails.]

Acceptance criteria:
- `mkdocs serve` runs locally and renders all pages without errors
- `mkdocs build --strict` produces a clean static site in `site/` with no warnings
- GitHub Actions workflow deploys on push to main (only when docs change)
- Site is accessible at the configured GitHub Pages URL
  (requires GitHub Pages enabled in repo Settings → Pages → Source: GitHub Actions)
- All navigation links work (no broken internal links)
- Search works (MkDocs Material built-in search)
- Dark/light theme toggle works
- Code blocks have copy buttons
- Mobile responsive (Material theme handles this)
- Getting Started guide walks through init → first run → output → diagnose
  as a complete beginner journey
- Reference section covers every CLI flag and every config key
- Every config key in config_defaults.sh is documented in reference/configuration.md
- Platform-specific install notes for macOS, Linux, and Windows (WSL)
- `tekhton --docs` prints the GitHub Pages URL and attempts to open it in the
  default browser; exits 0 regardless of whether the browser open succeeds
- Content is written for the "idea person who isn't a senior dev" audience,
  not just for engineers who already understand CI/CD pipelines
- All existing tests pass
- `bash -n` and `shellcheck` pass on any modified .sh files

Watch For:
- MkDocs Material is a pip package. Add it to `docs/requirements.txt` (separate
  from the indexer's `tools/requirements.txt`). The GitHub Actions workflow installs
  from `docs/requirements.txt`.
- Screenshots for the Watchtower guide: placeholder `<!-- TODO: screenshot -->` comments
  are acceptable for initial merge. Create `docs/assets/screenshots/` directory.
  Screenshots should be regenerated when the Watchtower UI changes.
- The configuration reference will be the most maintenance-heavy page. Consider
  generating it from config_defaults.sh comments (a simple script that extracts
  key=value + comment pairs). This keeps docs in sync with code.
- Custom domain setup (if using geoffgodwin.com/projects/tekhton): requires a
  CNAME file in the repo root or gh-pages branch, plus DNS configuration.
  GitHub Pages supports both apex domains and subdomains. For a subdirectory
  path on an existing domain, you'd need a reverse proxy or the Astro blog
  to handle routing. Simpler to use a subdomain (tekhton.geoffgodwin.com).
- Keep the docs conversational, not academic. "Here's what happens when you
  run this" > "The system invokes the following subsystems." Match the tone
  of this design discussion — technical but approachable.
- GitHub Pages must be configured in the repo's Settings → Pages before the
  first deployment will succeed. The workflow alone is not sufficient.

Seeds Forward:
- V4 docs expansion: API reference (when plugin system exists), multi-language,
  tutorial videos, interactive playground
- Config reference auto-generation script is reusable for any future
  configuration documentation needs
- The docs site structure mirrors the Watchtower tabs conceptually
  (getting started ≈ Live Run, concepts ≈ Milestone Map, reference ≈ Reports,
  troubleshooting ≈ --diagnose)
