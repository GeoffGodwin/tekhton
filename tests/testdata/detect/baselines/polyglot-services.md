## Tech Stack Detection Report

### Project Type: custom

### Languages
| Language | Confidence | Manifest |
|----------|------------|----------|
| go | medium | go.mod |

### Frameworks
(none detected)

### Detected Commands
| Type | Command | Source | Confidence |
|------|---------|--------|------------|
| test | `go test ./...` | github-actions CI | high |
| analyze | `go vet ./...` | github-actions CI | high |
| build | `go build ./...` | go.mod present | high |

### Entry Points
- `main.go`
- `Dockerfile`

### Services
| Service | Directory | Tech Stack | Source |
|---------|-----------|------------|--------|
| polyglot-services | . | unknown | k8s |

### CI/CD Configuration
| CI System | Build | Test | Lint | Deploy | Confidence |
|-----------|-------|------|------|--------|------------|
| github-actions | - | go test ./... | - | - | high |
| github-actions | - | - | go vet ./... | - | high |
| dockerfile | - | - | - | go | medium |

### Documentation Quality

**Score: 0/100**

- readme:0/30(missing)
- contributing:0/15
- api-docs:0/15
- architecture:0/20
- inline:0/20

