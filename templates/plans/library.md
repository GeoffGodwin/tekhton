# Design Document — Library / Package

<!-- Generated from sections below -->

## Developer Philosophy & Constraints
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What are your non-negotiable architectural rules? Examples: -->
<!-- - Zero runtime dependencies: the library ships nothing consumers didn't ask for -->
<!-- - Type-safe public API: every function has precise types, no `any` or `interface{}` -->
<!-- - Backward compatible: minor versions never break existing consumer code -->
<!-- - Fail explicitly: errors are returned, not swallowed; panics are bugs -->
<!-- - Tree-shakeable: unused exports must not increase bundle size -->
<!-- - Documentation-as-tests: every doc example is a runnable test -->
<!-- What patterns must every contributor follow? What anti-patterns are banned? -->

## Project Overview
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What does this library do in one sentence? -->
<!-- What problem does it solve for its consumers? -->
<!-- What existing library does it replace or improve? Why is a new library needed? -->
<!-- Target audience: frontend devs, backend devs, data engineers, general purpose? -->
<!-- License: MIT, Apache 2.0, GPL, commercial? -->
<!-- Is this a wrapper, a from-scratch implementation, or a port from another language? -->

## Tech Stack
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Language: TypeScript, Python, Rust, Go, Java, or other? -->
<!-- Build tool: tsc, Rollup, esbuild, cargo, setuptools, Gradle? -->
<!-- Package registry: npm, PyPI, crates.io, Maven Central, NuGet? -->
<!-- Test framework: Vitest, Jest, pytest, cargo test, JUnit? -->
<!-- Linter/formatter: ESLint, Ruff, clippy, golangci-lint? -->
<!-- Documentation: TypeDoc, Sphinx, rustdoc, JavaDoc, or manual? -->
<!-- CI: GitHub Actions, GitLab CI, CircleCI? -->
<!-- Minimum supported runtime versions: Node 18+? Python 3.10+? MSRV for Rust? -->

## Public API Surface
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- List every public function, class, type, or module as a ### sub-section. For each: -->
<!-- - Signature: name, parameters with types, return type -->
<!-- - Description: what it does, when to use it -->
<!-- - Parameters: describe each parameter, valid values, defaults -->
<!-- - Return value: what is returned? What about edge cases (empty input, null)? -->
<!-- - Throws/errors: what errors can this function produce? -->
<!-- - Example usage: at least one code example per function -->
<!-- - Complexity: time and space complexity if relevant -->
<!-- How is the API organized? (flat exports, namespaced modules, class methods) -->
<!-- What is the "80% use case" — the simplest correct invocation? -->

## Core Algorithms & Data Structures
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- What does the library do internally? For each algorithm or processing pipeline: -->
<!-- - Input: what data enters? Format? -->
<!-- - Processing: step-by-step description of the algorithm -->
<!-- - Output: what is produced? -->
<!-- - Complexity: time and space complexity -->
<!-- - Edge cases: empty input, very large input, malformed data -->
<!-- What data structures are used internally? Why? -->
<!-- Are there multiple strategy implementations? How is the right one selected? -->

## Configuration & Options
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- What can consumers configure? For each option: -->
<!-- - Option name, type, default value, description -->
<!-- - Valid range or enum of values -->
<!-- - What happens with an invalid value? (throw, clamp, ignore) -->
<!-- Configuration pattern: constructor options, builder pattern, global config, or per-call? -->
<!-- Show example configuration: -->
<!-- ```typescript -->
<!-- const client = new MyLib({ -->
<!--   timeout: 5000, -->
<!--   retries: 3, -->
<!--   logger: console, -->
<!--   mode: 'strict' -->
<!-- }) -->
<!-- ``` -->
<!-- Immutability: can config be changed after construction? -->

## Error Handling Strategy
<!-- PHASE:2 -->
<!-- How does the library report errors to consumers? -->
<!-- Error types: custom error classes, error codes, Result types, or language exceptions? -->
<!-- For each error type: name, when it occurs, what information it carries -->
<!-- Unrecoverable vs recoverable: which errors can consumers retry? -->
<!-- Error hierarchy: do errors extend a base library error type? -->
<!-- Validation errors: are they separate from runtime errors? -->
<!-- What happens on programmer error vs runtime error? (panic vs return error) -->

## Type System & Generics
<!-- PHASE:2 -->
<!-- How does the library use the type system? -->
<!-- Generic types: what functions or classes are generic? What constraints? -->
<!-- Type exports: what types are exported for consumers? -->
<!-- Utility types: any helper types (Partial<Config>, Result<T, E>)? -->
<!-- Type narrowing: how do consumers narrow union types? (type guards, discriminants) -->
<!-- Strictness: does the library work under strict mode (strictNullChecks, strict Rust)? -->

## Dependencies & Peer Dependencies
<!-- PHASE:2 -->
<!-- Runtime dependencies: list each with purpose and size impact -->
<!-- Peer dependencies: what must the consumer provide? (e.g., react >= 18) -->
<!-- Dev dependencies: testing, building, linting tools -->
<!-- Dependency philosophy: zero-dep, minimal, or batteries-included? -->
<!-- What happens if a dependency has a vulnerability? Update strategy? -->
<!-- Vendoring: is any dependency code vendored/inlined? Why? -->

## Compatibility & Platform Support
<!-- PHASE:2 -->
<!-- Supported runtime versions: Node 18+, Python 3.10+, Rust MSRV 1.70? -->
<!-- Browser support: Chrome, Firefox, Safari, Edge? Minimum versions? -->
<!-- Environment: Node.js, Deno, Bun, browser, workers, edge runtime? -->
<!-- Module formats: ESM, CJS, UMD, or all? -->
<!-- Platform-specific code: any OS-specific or platform-specific behavior? -->
<!-- Does the library use any native/FFI bindings? -->

## Bundle Size & Tree-Shaking
<!-- PHASE:2 -->
<!-- Target bundle size: minified + gzipped size budget -->
<!-- Tree-shaking: is every export independently importable? -->
<!-- Side effects: does the package.json declare sideEffects: false? -->
<!-- Code splitting: can consumers import sub-paths? (e.g., "mylib/utils") -->
<!-- What bloats bundle size? What measures prevent size regression? -->
<!-- Bundle analysis: how is bundle size tracked in CI? -->

## Performance Characteristics
<!-- PHASE:2 -->
<!-- Benchmarks: what operations are benchmarked? Target numbers? -->
<!-- Memory usage: allocation patterns, streaming vs buffering -->
<!-- Concurrency: is the library thread-safe? Async-safe? -->
<!-- Hot path optimization: what code paths are performance-critical? -->
<!-- What performance trade-offs were made? (speed vs memory, simplicity vs speed) -->
<!-- Comparison: how does performance compare to alternatives? -->

## Versioning & Release Strategy
<!-- PHASE:2 -->
<!-- Versioning: strict semver? What constitutes major, minor, patch? -->
<!-- Deprecation policy: how long are deprecated APIs supported? -->
<!-- Changelog: auto-generated from commits? Conventional commits? -->
<!-- Release process: manual or automated? Who can publish? -->
<!-- Pre-releases: alpha, beta, rc naming? When to use? -->
<!-- Breaking change process: RFC, migration guide, codemods? -->

## Documentation Strategy
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- API reference: auto-generated from source (TypeDoc, Sphinx, rustdoc)? -->
<!-- Guide/tutorial: getting started, common patterns, migration guides -->
<!-- Examples: standalone example projects or inline code examples? -->
<!-- Where is documentation hosted? (GitHub Pages, ReadTheDocs, docs.rs) -->
<!-- Documentation testing: are examples validated in CI? -->

## Config Architecture
<!-- REQUIRED -->
<!-- PHASE:3 -->
<!-- What values MUST live in config rather than hardcoded? -->
<!-- Show the complete default configuration object: -->
<!-- ```typescript -->
<!-- const DEFAULTS = { -->
<!--   timeout: 30000, -->
<!--   maxRetries: 3, -->
<!--   logLevel: 'warn', -->
<!--   // ... every configurable value with its default -->
<!-- } -->
<!-- ``` -->
<!-- What is the config merge strategy? (deep merge, shallow merge, replace) -->
<!-- Can config be changed at runtime? What effect does it have? -->

## Testing Strategy
<!-- PHASE:3 -->
<!-- Unit tests: what logic is tested? Coverage target? -->
<!-- Property-based tests: any fuzz or property tests? -->
<!-- Integration tests: tests against real dependencies (if any) -->
<!-- Compatibility tests: tested against multiple runtime versions? CI matrix? -->
<!-- Benchmark tests: performance regression tests? -->
<!-- Consumer tests: do you test against real consumer projects? -->

## Naming Conventions
<!-- PHASE:3 -->
<!-- Code naming: per-language conventions -->
<!-- Public API naming: what naming rules apply to exported symbols? -->
<!-- File structure: one module per file? Grouped by feature or layer? -->
<!-- Test file naming: co-located or separate test directory? -->
<!-- What domain terms map to what code concepts? -->

## Open Design Questions
<!-- REQUIRED -->
<!-- PHASE:3 -->
<!-- What decisions are you deliberately deferring? -->
<!-- What needs usage data or community feedback before you can decide? -->
<!-- Example: "Unsure if streaming API is needed — start with batch, add streaming if demand" -->
<!-- Example: "Plugin system scope TBD — evaluate after v1.0 based on extension requests" -->
<!-- List each open question with the information needed to resolve it. -->

## What Not to Build Yet
<!-- PHASE:3 -->
<!-- What features are explicitly deferred? -->
<!-- For each: what it is, why it's deferred, what milestone might add it -->
<!-- Example: "CLI wrapper — library first, CLI if consumers request it" -->
<!-- Example: "Framework-specific bindings (React hooks, Vue composables) — core library first" -->
