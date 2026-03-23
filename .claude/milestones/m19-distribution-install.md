#### Milestone 19: Distribution & Install Experience
Create a cross-platform install script, GitHub Releases workflow with versioned
tarballs, and a non-intrusive update check mechanism. The goal: a new user goes
from "what is Tekhton?" to `tekhton --init` in under 60 seconds, on any platform.

Today's experience (git clone, manual alias) is fine for contributors but hostile
to adopters. This milestone makes Tekhton installable with a single command and
self-aware of its own version lifecycle.

Files to create:
- `install.sh` — Cross-platform install script:
  **Invocation:** `curl -sSL https://raw.githubusercontent.com/geoffgodwin/tekhton/main/install.sh | bash`
  Or with options: `curl ... | bash -s -- --prefix=/opt/tekhton`

  **Platform detection:**
  - Detect OS: Linux, macOS, Windows (WSL), Windows (Git Bash → error with guidance)
  - Detect architecture: x86_64, arm64 (for future binary distribution)
  - Detect shell: bash version check (≥4.0 required)
  - macOS: check if Homebrew bash is available, guide user to install if not
    (`brew install bash` + explain why macOS bash 3.2 won't work)
  - Windows without WSL: print clear error with WSL install link and exit
  - Git Bash: print clear error explaining bash 4+ features are required

  **Installation steps:**
  1. Create install directory (default: `~/.tekhton/`)
     - Configurable via `--prefix=DIR`
     - On Windows/WSL: default to `~/.tekhton/` within WSL home
  2. Download latest release tarball from GitHub Releases
     - Verify SHA256 checksum (downloaded alongside tarball)
     - Fall back to git clone if GitHub Releases not available (dev installs)
  3. Extract to `~/.tekhton/versions/X.Y.Z/`
  4. Symlink `~/.tekhton/current/` → `~/.tekhton/versions/X.Y.Z/`
  5. Create executable symlink or PATH entry:
     - If `/usr/local/bin` is writable: symlink `tekhton` there
     - Otherwise: add `~/.tekhton/current` to PATH in shell rc file
     - Detect shell rc file: `.bashrc`, `.zshrc`, `.profile`, `.bash_profile`
     - Ask before modifying rc file (with preview of what will be added)
  6. Verify installation: `tekhton --version`
  7. Print success message with next steps:
     ```
     ✓ Tekhton X.Y.Z installed successfully!

     Next steps:
       cd /path/to/your/project
       tekhton --init

     Documentation: https://geoffgodwin.github.io/tekhton/
     ```

  **Flags:**
  - `--prefix=DIR` — Install to custom directory (default: ~/.tekhton)
  - `--version=X.Y.Z` — Install specific version (default: latest)
  - `--no-path` — Don't modify shell rc files (user manages PATH manually)
  - `--uninstall` — Remove Tekhton installation and PATH entries

  **Uninstall:** `install.sh --uninstall` or `tekhton --uninstall`:
  - Remove `~/.tekhton/` directory
  - Remove symlink from `/usr/local/bin/`
  - Remove PATH entry from shell rc file (if added by installer)
  - Does NOT remove project-level `.claude/` directories

- `lib/update_check.sh` — Version check and update notification:
  **Check mechanism** (`check_for_updates()`):
  - Run at most once per 24 hours (timestamp stored in `~/.tekhton/.last_update_check`)
  - Fetch latest release tag from GitHub API:
    `curl -sSL https://api.github.com/repos/geoffgodwin/tekhton/releases/latest`
  - Compare with current TEKHTON_VERSION using semver comparison
  - If newer version available: print one-line notice AFTER pipeline output:
    ```
    ℹ Tekhton X.Y.Z is available (you have X.Y.Z). Run: tekhton --update
    ```
  - Never interrupts pipeline execution. Notice appears only at the very end.
  - If no internet / API rate limited / check fails: silently skip (no error)

  **Update mechanism** (`perform_update()`):
  - `tekhton --update` triggers manual update:
    1. Check for latest version (same as above)
    2. If current: "You're already on the latest version."
    3. If newer: show version diff summary (changelog excerpt if available)
    4. Download new tarball to `~/.tekhton/versions/X.Y.Z/`
    5. Verify SHA256 checksum
    6. Update `~/.tekhton/current` symlink
    7. Print: "Updated to X.Y.Z. See changelog: tekhton --docs changelog"
  - `tekhton --update --check` only checks, doesn't install (for scripts/CI)

  **Version pinning** (for enterprises):
  - `TEKHTON_UPDATE_CHECK=false` in pipeline.conf or env var disables ALL
    update checks (no network calls, no notices)
  - `TEKHTON_PIN_VERSION=3.14.0` in pipeline.conf prevents --update from
    upgrading past the pinned version. Useful for teams that want stability.

- `.github/workflows/release.yml` — GitHub Actions release workflow:
  Triggered by git tags matching `v*`:
  ```yaml
  name: Release
  on:
    push:
      tags: ['v*']
  permissions:
    contents: write
  jobs:
    release:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
        - name: Create tarball
          run: |
            VERSION=${GITHUB_REF_NAME#v}
            tar -czf tekhton-${VERSION}.tar.gz \
              --transform "s,^,tekhton-${VERSION}/," \
              --exclude='.git*' --exclude='site/' --exclude='*.pyc' \
              --exclude='__pycache__' --exclude='.claude/' \
              tekhton.sh lib/ stages/ prompts/ templates/ tools/ \
              install.sh LICENSE README.md
        - name: Generate checksums
          run: sha256sum tekhton-*.tar.gz > SHA256SUMS
        - name: Create GitHub Release
          uses: softprops/action-gh-release@v1
          with:
            files: |
              tekhton-*.tar.gz
              SHA256SUMS
            generate_release_notes: true
  ```

Files to modify:
- `tekhton.sh` — Add flag handling:
  - `--update` → call `perform_update()`
  - `--update --check` → call `check_for_updates()` with forced check
  - `--uninstall` → call install.sh --uninstall
  - `--docs` → open docs URL in browser
  - At end of every pipeline run (success or failure): call
    `check_for_updates()` (respects 24-hour cooldown and config disable)
  - Source lib/update_check.sh

- `lib/config_defaults.sh` — Add:
  TEKHTON_UPDATE_CHECK=true (check for updates, set false to disable),
  TEKHTON_PIN_VERSION="" (empty = no pin, set to version string to pin).

- `lib/config.sh` — Validate TEKHTON_PIN_VERSION is valid semver or empty.

Acceptance criteria:
- `curl ... | bash` installs Tekhton to ~/.tekhton/ on Linux
- `curl ... | bash` installs Tekhton to ~/.tekhton/ on macOS (with bash 4+ check)
- `curl ... | bash` installs Tekhton to ~/.tekhton/ on Windows WSL
- Git Bash on Windows prints clear error with WSL guidance
- Install script detects bash version < 4 and prints upgrade instructions
- `--prefix` flag installs to custom directory
- `--version` flag installs specific version
- `--no-path` flag skips shell rc file modification
- `tekhton --version` works after install (PATH set up correctly)
- `tekhton --uninstall` removes installation cleanly
- Shell rc file modification shows preview and asks before writing
- SHA256 checksum verified on download (failure = abort with error)
- `tekhton --update` downloads and installs newer version
- `tekhton --update` on latest version says "already up to date"
- `tekhton --update --check` reports available version without installing
- Update check runs at most once per 24 hours (cooldown file)
- Update notice appears after pipeline output, never during
- No network calls when TEKHTON_UPDATE_CHECK=false
- TEKHTON_PIN_VERSION prevents upgrade past pinned version
- GitHub Actions creates release with tarball + SHA256SUMS on version tag
- Tarball extracts cleanly and contains all necessary files
- Tarball excludes: .git, site/, __pycache__, .claude/
- All existing tests pass
- `bash -n install.sh lib/update_check.sh` passes
- `shellcheck install.sh lib/update_check.sh` passes

Watch For:
- Shell rc file detection is tricky. Users may have .bashrc, .bash_profile,
  .zshrc, or .profile. Detect the current shell (`$SHELL`) and modify the
  appropriate file. Always backup before modifying (`cp ~/.bashrc ~/.bashrc.tekhton-backup`).
- The install script itself must work with bash 3.2 (it runs on the user's
  system BEFORE Tekhton is installed — macOS default bash is 3.2). Keep the
  install script bash-3-compatible. Only Tekhton itself requires bash 4+.
- GitHub API rate limit: unauthenticated requests get 60/hour. The 24-hour
  cooldown prevents hitting this, but if multiple Tekhton projects check in
  rapid succession, they could hit it. Cache the result per-user, not per-project.
- Symlink approach (`~/.tekhton/current → ~/.tekhton/versions/X.Y.Z`) enables
  instant rollback: `ln -sf ~/.tekhton/versions/3.13.0 ~/.tekhton/current`.
  Document this as a recovery mechanism.
- The tarball must NOT include `.claude/` (that's project-level config, not
  distribution content). It must include `templates/` (which --init copies
  into projects).
- Windows WSL path handling: `~/.tekhton/` inside WSL is NOT visible from
  Windows Explorer by default. The install script should note this.
- `curl | bash` is controversial in security circles. Offer an alternative:
  "Download install.sh, review it, then run it." Include a verification step
  for the install script itself (GPG signature or checksums).

Seeds Forward:
- V4 Homebrew tap: formula wraps the tarball download
- V4 Docker image: uses install.sh internally for consistency
- V4 npm/pip wrapper: thin shim that calls install.sh
- The version symlink structure enables side-by-side version testing
  (run old version on one project, new on another)
- Signed releases (GPG) are a V4 enterprise requirement
- The update check infrastructure can be extended for plugin updates
  when plugins exist
