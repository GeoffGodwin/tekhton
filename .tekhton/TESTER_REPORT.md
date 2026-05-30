## Planned Tests
- [x] `internal/detect/detect_test.go` — engine invariants (languages-first, error propagation, cache reset, Summary.ProjectType fallback)
- [x] `internal/detect/languages_test.go` — LanguagesDetector happy paths, confidence scoring, framework detection, CLAUDE.md fallback
- [x] `internal/detect/report_test.go` — Render() markdown shape matches bash baseline format
- [x] `internal/detect/readonly_test.go` — package read-only contract (no forbidden write APIs)
- [x] `cmd/tekhton/detect_test.go` — CLI smoke tests (help, --json shape, --markdown default, mutual-exclusion guard)
- [x] `tests/test_detect_parity.sh` — byte-identical parity gate across three fixtures
- [ ] `internal/detect/workspaces_test.go` — add Lerna, Nx, Cargo, Gradle, Maven workspace coverage
- [ ] `internal/detect/ci_test.go` — add GitLab CI, CircleCI, Jenkins, Bitbucket Pipelines coverage
- [ ] `internal/detect/infrastructure_test.go` — add CDK, CloudFormation/SAM, Ansible coverage
- [ ] `internal/detect/test_frameworks_test.go` — add Go, Rust, Ruby, Java, C#, Dart, Shell coverage
- [ ] `internal/detect/doc_quality_test.go` — add API-docs scoring, architecture scoring, individual subscore bounds
- [ ] `internal/detect/services_test.go` — add Kubernetes service detection coverage
- [ ] `internal/detect/ai_artifacts_test.go` — add known_dirs, known_files, known_globs heuristic coverage

## Test Run Results
Passed: 25 Go + 499 Shell  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/detect/detect_test.go`
- [x] `internal/detect/languages_test.go`
- [x] `internal/detect/report_test.go`
- [x] `internal/detect/readonly_test.go`
- [x] `cmd/tekhton/detect_test.go`
- [x] `tests/test_detect_parity.sh`
- [ ] `internal/detect/workspaces_test.go`
- [ ] `internal/detect/ci_test.go`
- [ ] `internal/detect/infrastructure_test.go`
- [ ] `internal/detect/test_frameworks_test.go`
- [ ] `internal/detect/doc_quality_test.go`
- [ ] `internal/detect/services_test.go`
- [ ] `internal/detect/ai_artifacts_test.go`
