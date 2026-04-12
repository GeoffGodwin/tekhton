# Milestone 78: Install UX — curl|bash Promotion + Homebrew Tap
<!-- milestone-meta
id: "78"
status: "pending"
-->

## Overview

Developer feedback: "Getting Tekhton onto a machine is too many steps. It
should be a single line." Today the README leads with a four-step flow —
`git clone`, `cd`, `chmod +x`, `./tekhton.sh --init`. M19 already shipped
`install.sh` supporting `curl -sSL ... | bash`, but the README never
promoted it above the manual flow, so nobody uses it.

M78 is a **docs + packaging** milestone, not a code milestone. It:

1. Promotes `curl | bash` to the README headline install.
2. Adds a Homebrew tap (`homebrew-tekhton`) with a minimal Formula.
3. Wires a tag-push GitHub Action to auto-update the Formula's version
   and sha256.

No changes to `tekhton.sh` behavior. No new config vars. Strictly
distribution polish.

## Design Decisions

### 1. curl|bash is the headline install

Replace the README's current "Install" section with one line:

```bash
curl -sSL https://raw.githubusercontent.com/geoffgodwin/tekhton/main/install.sh | bash
```

Keep the existing manual git-clone path as a secondary "from source"
subsection below, for hackers. Order matters: the first code block a user
sees should be the one-liner.

`install.sh` already exists from M19 — this milestone does NOT modify the
installer itself. It only changes where it appears in README and adds the
Homebrew alternative.

### 2. Homebrew tap, not homebrew-core

We ship a user-owned **tap** (`geoffgodwin/homebrew-tekhton`), not a PR to
homebrew-core. Taps require no review, give us release control, and are
installable via `brew install geoffgodwin/tekhton/tekhton`. Going to
homebrew-core is a later, optional polish — out of scope.

### 3. Formula is minimal — download release tarball + install

```ruby
class Tekhton < Formula
  desc "Multi-agent development pipeline built on Claude CLI"
  homepage "https://github.com/geoffgodwin/tekhton"
  url "https://github.com/geoffgodwin/tekhton/archive/refs/tags/v3.78.0.tar.gz"
  sha256 "PLACEHOLDER"
  license "MIT"

  depends_on "bash"
  depends_on "jq"
  depends_on "python@3.12"

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"tekhton.sh" => "tekhton"
  end

  test do
    assert_match "Tekhton", shell_output("#{bin}/tekhton --version")
  end
end
```

Dependencies are the same hard deps Tekhton already requires. The test
block exercises the `--version` flag — cheap smoke test.

### 4. Auto-update the formula on tag push

New GitHub Actions workflow `.github/workflows/brew-bump.yml` in the
**main tekhton repo** (not the tap repo). On `push: tags: v*`:

1. Compute the tag's tarball sha256.
2. Clone `geoffgodwin/homebrew-tekhton`.
3. Run `sed -i` to swap the `url` and `sha256` lines in `Formula/tekhton.rb`.
4. Commit + push back to the tap repo.

Cross-repo push requires a Personal Access Token (or fine-grained token)
stored as repo secret `HOMEBREW_TAP_PAT`. Setting this up is a manual
one-time step by the maintainer — document in `docs/RELEASING.md`.

### 5. Keep Linux/WSL advice too

README adds a short "Platform notes" subsection under Install:

- **macOS:** `brew install geoffgodwin/tekhton/tekhton` (preferred) or
  the curl one-liner.
- **Linux / WSL:** the curl one-liner.
- **From source:** `git clone` + `./install.sh` (unchanged).

No attempt at apt/yum/pacman packaging — out of scope. curl|bash works
everywhere and is already what the M19 installer targets.

### 6. Verify the installer works post-release

The existing M19 release workflow creates the GitHub release tarball.
Once that tarball is up, the brew-bump workflow runs against it. Add a
10-line test job to `brew-bump.yml` that, after pushing the formula
update, runs `brew install geoffgodwin/tekhton/tekhton` in a macOS
runner and greps the installed `tekhton --version` output for the new
version string. If the install fails, the workflow fails — catches
formula bugs before users hit them.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| README sections rewritten | 1 | Install section — one-liner headline |
| New CI workflow | 1 | `.github/workflows/brew-bump.yml` |
| New external repo | 1 | `geoffgodwin/homebrew-tekhton` (manual setup) |
| New tap files | 2 | `Formula/tekhton.rb`, `README.md` for the tap |
| New docs | 1 | `docs/RELEASING.md` maintainer runbook |
| New config vars | 0 | — |
| Code changes to tekhton.sh | 0 | — |

## Implementation Plan

### Step 1 — README install section rewrite

Edit `README.md` — replace the current Install section with:

```markdown
## Install

### Quickest path

```bash
curl -sSL https://raw.githubusercontent.com/geoffgodwin/tekhton/main/install.sh | bash
```

This installs Tekhton to `~/.tekhton` and adds `tekhton` to your PATH.

### macOS (Homebrew)

```bash
brew install geoffgodwin/tekhton/tekhton
```

### From source

```bash
git clone https://github.com/geoffgodwin/tekhton.git
cd tekhton && ./install.sh
```
```

No other README changes in this milestone — the larger README restructure
is M79.

### Step 2 — Create the Homebrew tap repo

**Manual, one-time, maintainer action.** Create
`https://github.com/geoffgodwin/homebrew-tekhton` with:

- `Formula/tekhton.rb` — initial formula pointing at the current
  `v3.78.0` release tarball. Compute sha256 via
  `curl -sL https://github.com/.../v3.78.0.tar.gz | shasum -a 256`.
- `README.md` — "This is the Homebrew tap for Tekhton. Install with
  `brew install geoffgodwin/tekhton/tekhton`."

Commit to the tap repo's main branch.

Note: this milestone's PR cannot include the tap repo changes — they live
in a different repo. The milestone's Acceptance Criteria captures the
expectation; the actual external-repo setup is a follow-on manual step
documented in `docs/RELEASING.md`.

### Step 3 — Tekhton-repo workflow: brew-bump

Create `.github/workflows/brew-bump.yml`:

```yaml
name: Bump Homebrew Formula
on:
  push:
    tags: ['v*']

jobs:
  bump:
    runs-on: ubuntu-latest
    steps:
      - name: Compute tarball sha256
        id: sha
        run: |
          TAG="${GITHUB_REF_NAME}"
          URL="https://github.com/${GITHUB_REPOSITORY}/archive/refs/tags/${TAG}.tar.gz"
          SHA=$(curl -sL "$URL" | sha256sum | awk '{print $1}')
          echo "sha256=$SHA" >> "$GITHUB_OUTPUT"
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"
      - name: Clone tap repo
        uses: actions/checkout@v4
        with:
          repository: geoffgodwin/homebrew-tekhton
          token: ${{ secrets.HOMEBREW_TAP_PAT }}
          path: tap
      - name: Update formula
        run: |
          cd tap
          sed -i -E \
            -e "s|url \".*\"|url \"https://github.com/${GITHUB_REPOSITORY}/archive/refs/tags/${{ steps.sha.outputs.tag }}.tar.gz\"|" \
            -e "s|sha256 \".*\"|sha256 \"${{ steps.sha.outputs.sha256 }}\"|" \
            Formula/tekhton.rb
      - name: Commit and push
        run: |
          cd tap
          git config user.name "tekhton-bot"
          git config user.email "noreply@tekhton.dev"
          git add Formula/tekhton.rb
          git commit -m "tekhton ${{ steps.sha.outputs.tag }}"
          git push
```

Verify locally (without pushing) using `act` or a dry-run branch before
merging.

### Step 4 — brew-install smoke test job

Append to the same workflow:

```yaml
  smoke-test:
    needs: bump
    runs-on: macos-latest
    steps:
      - name: brew install from tap
        run: |
          brew tap geoffgodwin/tekhton
          brew install tekhton
          tekhton --version | grep -q "${GITHUB_REF_NAME#v}"
```

If this fails, we ship a broken formula — better to know at tag time.

### Step 5 — Maintainer runbook

Create `docs/RELEASING.md` with:

- Prerequisites: `HOMEBREW_TAP_PAT` secret set, tap repo exists with
  initial formula.
- Release cut: bump `TEKHTON_VERSION` in `tekhton.sh`, commit, tag
  `vX.Y.Z`, push tag.
- What happens automatically after tag push (M19 release + brew-bump +
  smoke test).
- How to roll back a bad formula (manual revert commit in the tap repo).

Short — 60 to 80 lines max. Don't re-document the M19 release process.

### Step 6 — Shellcheck + tests + version bump

No shell script changes in this milestone, so shellcheck is a no-op but
still runs clean.

```bash
bash tests/run_tests.sh
```

Edit `tekhton.sh` — `TEKHTON_VERSION="3.78.0"`.
Edit manifest — M78 row with `depends_on=m72`, group `devx`.

## Files Touched

### Added
- `.github/workflows/brew-bump.yml`
- `docs/RELEASING.md`
- `.claude/milestones/m78-install-ux-curl-brew.md` — this file

### Modified
- `README.md` — rewrite Install section
- `tekhton.sh` — `TEKHTON_VERSION` to `3.78.0`
- `.claude/milestones/MANIFEST.cfg` — M78 row

### External (manual, not in this PR)
- `geoffgodwin/homebrew-tekhton` repo — create + initial formula
- Repo secret `HOMEBREW_TAP_PAT` — set by maintainer

## Acceptance Criteria

- [ ] README Install section leads with the `curl | bash` one-liner
- [ ] README includes `brew install geoffgodwin/tekhton/tekhton` as macOS
      option
- [ ] README retains "from source" path for hackers as a secondary option
- [ ] `.github/workflows/brew-bump.yml` exists and triggers on tag push
- [ ] Workflow computes tarball sha256 and updates `Formula/tekhton.rb`
      in the tap repo
- [ ] Workflow includes a macOS smoke-test job that installs via `brew`
      and verifies `tekhton --version` matches the tag
- [ ] `docs/RELEASING.md` documents the release process including the
      manual tap-repo prerequisites
- [ ] `tekhton.sh` `TEKHTON_VERSION` is `3.78.0`
- [ ] `.claude/milestones/MANIFEST.cfg` contains the M78 row
      (`depends_on=m72`, group `devx`)
- [ ] `bash tests/run_tests.sh` passes with zero failures
- [ ] `shellcheck` reports zero warnings on all shell files (no shell
      files changed, but baseline must stay clean)

## Watch For

- **The tap repo is external.** This milestone's PR cannot create the
  `geoffgodwin/homebrew-tekhton` repo — that's a manual, one-time
  maintainer step. Capture it as a prerequisite in `docs/RELEASING.md`
  and the acceptance criteria. Don't block the milestone on it.
- **PAT scope.** `HOMEBREW_TAP_PAT` needs `contents: write` on the tap
  repo ONLY. Fine-grained token strongly preferred over classic token.
- **sha256 drift.** GitHub sometimes regenerates release tarballs (e.g.,
  after tag re-signing) which changes the sha256. If this happens, the
  formula breaks silently for users. The smoke-test job catches this,
  but document it in `docs/RELEASING.md` so the maintainer knows what
  "brew install failed after 24 hours" means.
- **install.sh lives in main repo, not tap.** The tap formula does NOT
  shell out to `install.sh` — it does a plain tarball install. Keep the
  two paths separate so a failure in one doesn't cascade to the other.
- **No homebrew-core.** Do NOT open a homebrew-core PR as part of this
  milestone. That path has a multi-week review cycle and strict rules
  about formula style. A user-owned tap sidesteps all of it.
- **README is not fully restructured here.** M79 handles the broader
  README slim-down. M78 makes a single targeted edit to the Install
  section only. Don't scope-creep.
- **Formula bash dep.** `depends_on "bash"` on macOS installs a modern
  bash from Homebrew, since Apple ships bash 3.2. Tekhton requires 4+.
  Verify the formula's symlink resolves to Homebrew bash, not system
  bash, at runtime — the `install.sh` equivalent already handles this,
  but the brew path needs its own check.
- **File-length guardrail.** `docs/RELEASING.md` stays under 150 lines.
  If longer, split into `docs/releasing/` subfolder.

## Seeds Forward

- **homebrew-core submission.** Once the tap is stable and well-used,
  submitting to homebrew-core removes the tap prefix (just
  `brew install tekhton`). Requires passing their `audit` ruleset,
  steady maintenance cadence, and reviewer time. Flag as a future
  distribution polish milestone.
- **apt / yum / pacman.** Linux package managers each need their own
  packaging workflow. A future devx milestone could generate a `.deb`
  and publish to a Cloudsmith or similar PPA. Out of scope.
- **Docker image.** A `ghcr.io/geoffgodwin/tekhton:vX.Y.Z` image with
  the pipeline pre-installed would make CI integration trivial. Simple
  to add (one Dockerfile + one workflow) — consider as a follow-up.
- **Windows native install.** PowerShell or Scoop support. Tekhton's
  bash dependency makes this non-trivial; WSL is the recommended path
  for now, but a Scoop manifest could lower the barrier for Windows
  users who already have WSL.
- **Auto-update within tekhton.** A `tekhton --self-update` subcommand
  could re-run `install.sh` or check for a new version. Small feature,
  low priority compared to install-time polish.
