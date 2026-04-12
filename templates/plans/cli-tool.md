# Design Document — CLI Tool

<!-- Generated from sections below -->

## Developer Philosophy & Constraints
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What are your non-negotiable architectural rules? Examples: -->
<!-- - Unix philosophy: do one thing well, compose with other tools via pipes -->
<!-- - Fail fast and loud: invalid input causes immediate, clear error messages -->
<!-- - Zero-config defaults: tool works out of the box, config only for customization -->
<!-- - Offline-first: no network calls unless the user explicitly opts in -->
<!-- - Deterministic output: same input always produces same output (no timestamps in output by default) -->
<!-- What patterns must every contributor follow from day one? What anti-patterns are banned? -->

## Project Overview
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What does this tool do in one sentence? -->
<!-- Who uses it? (developers, sysadmins, data engineers, end users) -->
<!-- What existing tool or workflow does it replace or improve? -->
<!-- What is the distribution model? (open source, commercial, internal) -->
<!-- What is the expected invocation frequency? (once a day, 100x per minute in CI) -->

## Tech Stack
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Language: Rust, Go, Python, Node.js, Bash, or other? Why? -->
<!-- Argument parsing: clap, cobra, argparse, yargs, or custom? -->
<!-- Serialization: serde, encoding/json, or language built-in? -->
<!-- Testing framework: what runs unit and integration tests? -->
<!-- Distribution: Homebrew, npm, pip, cargo, apt, binary releases? -->
<!-- Build tool: cargo, go build, pyinstaller, pkg, or other? -->

## Command Taxonomy
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Is this a single-command tool or a multi-command CLI (like git)? -->
<!-- List every command and subcommand as a ### sub-section. For each: -->
<!-- - Syntax: `tool command [flags] <args>` -->
<!-- - Description: what it does in one sentence -->
<!-- - Required arguments and their types -->
<!-- - Optional flags with defaults and descriptions -->
<!-- - Example invocations (at least 2 per command) -->
<!-- Example sub-sections: ### init, ### run, ### config set, ### list -->

## Input Sources & Formats
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- What does the tool read? For each input source: -->
<!-- - File formats: JSON, YAML, TOML, CSV, plain text, binary? -->
<!-- - Stdin: does the tool accept piped input? What format? -->
<!-- - Environment variables: which ones are read? Precedence vs config file? -->
<!-- - Config files: path, format, discovery order (~/.config/tool, ./.toolrc, etc.) -->
<!-- - Command-line arguments: positional vs named, type validation -->
<!-- How are conflicting inputs resolved? What is the precedence order? -->
<!-- What happens when input is malformed? (exit code, error message format) -->

## Output Formatting & Modes
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- What does the tool produce? For each output type: -->
<!-- - Stdout: human-readable text, JSON, CSV, or structured? -->
<!-- - Stderr: where do errors, warnings, and progress go? -->
<!-- - Files: does the tool create or modify files? Where? -->
<!-- - Exit codes: list every exit code and its meaning (0=success, 1=error, etc.) -->
<!-- Output modes: human (colored, formatted), machine (JSON/CSV), quiet, verbose -->
<!-- How is output controlled? (--format json, --quiet, --verbose, --no-color) -->
<!-- Piping behavior: does the tool detect when stdout is not a TTY? -->

## Configuration System
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- Config file format: TOML, YAML, JSON, INI, or dotfile? -->
<!-- Config file locations: global (~/.config/tool/), local (./.toolrc), or both? -->
<!-- Discovery order: CLI flags > env vars > local config > global config > defaults -->
<!-- Show example config with actual keys and default values: -->
<!-- ```toml -->
<!-- [core] -->
<!-- output_format = "text" -->
<!-- color = "auto" -->
<!-- verbose = false -->
<!-- -->
<!-- [paths] -->
<!-- cache_dir = "~/.cache/tool" -->
<!-- ``` -->
<!-- What config changes require a restart vs take effect immediately? -->
<!-- Is there a `tool config` subcommand for managing config? -->

## Core Processing Logic
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- Describe the main processing pipeline: input → transform → output -->
<!-- What is the algorithm or workflow? Step by step. -->
<!-- What are the computational complexity characteristics? -->
<!-- Are there stages that can be parallelized? -->
<!-- What are the failure modes at each stage? -->
<!-- What intermediate state is created? Where is it stored? -->

## Error Handling & Diagnostics
<!-- PHASE:2 -->
<!-- How does the tool report errors? (stderr messages, exit codes, log files) -->
<!-- Error message format: prefix (Error:, Warning:), color, suggestions? -->
<!-- What happens on: invalid arguments, missing files, permission denied, network error? -->
<!-- Does the tool suggest fixes? ("Did you mean...?", "Try running X first") -->
<!-- Verbose/debug mode: what additional information is shown? -->
<!-- How are unexpected errors handled? (panic, stack trace, bug report URL) -->

## Shell Integration
<!-- PHASE:2 -->
<!-- Tab completion: supported shells (bash, zsh, fish)? How is it installed? -->
<!-- Shell aliases or wrapper functions recommended? -->
<!-- Piping support: can the tool be used in the middle of a pipe chain? -->
<!-- Signal handling: what happens on SIGINT (Ctrl+C), SIGTERM, SIGHUP? -->
<!-- Color output: when is color used? How is it disabled? (--no-color, NO_COLOR env) -->
<!-- Progress indicators: spinners, progress bars, or none? When are they shown? -->

## File System Operations
<!-- PHASE:2 -->
<!-- What files/directories does the tool create, read, modify, or delete? -->
<!-- What is the default output location? Can it be overridden? -->
<!-- Atomic writes: are file operations atomic? What happens on interruption? -->
<!-- Temporary files: where are they created? How are they cleaned up? -->
<!-- Lock files: does the tool use lock files for concurrent access? -->
<!-- Permissions: what file permissions are set on created files? -->

## Performance & Resource Usage
<!-- PHASE:2 -->
<!-- Expected performance for common operations (files per second, MB/s throughput) -->
<!-- Memory usage profile: streaming vs loading everything into memory -->
<!-- Large input handling: what happens with 1GB files? 1M records? -->
<!-- Parallelism: multi-threaded? Worker count configurable? -->
<!-- Caching: does the tool cache anything? Where? Invalidation strategy? -->

## Versioning & Compatibility
<!-- PHASE:2 -->
<!-- Versioning scheme: semver? -->
<!-- CLI interface stability: when can flags/commands change? Deprecation policy? -->
<!-- Output format stability: is JSON output schema versioned? -->
<!-- Config file versioning: how are old config files handled after upgrades? -->
<!-- Backward compatibility guarantees: what will never break between minor versions? -->

## Distribution & Installation
<!-- PHASE:2 -->
<!-- How do users install this tool? List every supported method: -->
<!-- - Package managers: brew, apt, pacman, chocolatey, scoop -->
<!-- - Language-specific: npm, pip, cargo install, go install -->
<!-- - Binary releases: GitHub Releases, direct download -->
<!-- - Build from source: git clone + build instructions -->
<!-- Cross-compilation targets: Linux, macOS, Windows? ARM? -->
<!-- Update mechanism: self-update command, or manual only? -->
<!-- Minimum system requirements: OS versions, dependencies -->

## Documentation Strategy
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- What documentation does this project ship? (README only, README + docs/ site, man pages) -->
<!-- Where is documentation hosted? (GitHub, GitHub Pages, ReadTheDocs, docs.rs, man page) -->
<!-- What surfaces must be documented? (CLI flags, subcommands, config keys, exit codes) -->
<!-- On every feature change, which docs must be updated in the same commit? -->
<!-- Is doc freshness strict (block the merge) or warn-only? -->
<!-- Any auto-generation tooling? (help2man, cobra-doc, argparse-generated docs) -->

## Testing Strategy
<!-- PHASE:2 -->
<!-- Unit tests: what logic is unit tested? -->
<!-- Integration tests: how are CLI invocations tested? (snapshot tests, output comparison) -->
<!-- Fixture files: where are test inputs stored? -->
<!-- Platform testing: tested on Linux, macOS, Windows? CI matrix? -->
<!-- Performance benchmarks: are there regression benchmarks? -->

## Naming Conventions
<!-- PHASE:3 -->
<!-- Code naming: per-language conventions (snake_case, camelCase, etc.) -->
<!-- Command naming: kebab-case (my-command) or space-separated (my command)? -->
<!-- Flag naming: --long-flag, -s short flag? Consistency rules? -->
<!-- Environment variable naming: TOOL_UPPER_SNAKE? Prefix? -->
<!-- What domain terms map to what code concepts? -->

## Config Architecture
<!-- REQUIRED -->
<!-- PHASE:3 -->
<!-- What values MUST live in config rather than hardcoded? -->
<!-- Config format and loading strategy (see Configuration System section for details) -->
<!-- Show the COMPLETE default config with all keys and their default values -->
<!-- What is the config override hierarchy? (defaults → global config → local config → env → flags) -->
<!-- How does a user reset to defaults? -->

## Open Design Questions
<!-- REQUIRED -->
<!-- PHASE:3 -->
<!-- What decisions are you deliberately deferring? -->
<!-- What needs user feedback before you can decide? -->
<!-- Example: "Unsure if we need a daemon mode or if CLI invocations are sufficient" -->
<!-- Example: "Plugin system scope TBD — start with built-in commands only" -->
<!-- List each open question with the information needed to resolve it. -->

## What Not to Build Yet
<!-- PHASE:3 -->
<!-- What features are explicitly deferred? -->
<!-- For each: what it is, why it's deferred, what milestone might add it -->
<!-- Example: "GUI wrapper — CLI first, evaluate GUI need after v1.0" -->
<!-- Example: "Plugin system — need stable internal API before exposing to third parties" -->
