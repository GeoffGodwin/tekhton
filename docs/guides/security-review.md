# Security Review

Tekhton includes a dedicated security agent that reviews every code change for
vulnerabilities before it reaches the code reviewer.

## How It Works

The security agent runs after the coder stage and before the code reviewer. It
scans the implementation for:

- **OWASP Top 10** — injection, broken auth, sensitive data exposure, XXE, broken
  access control, security misconfiguration, XSS, insecure deserialization, known
  vulnerable components, insufficient logging
- **Secrets and credentials** — hardcoded API keys, passwords, tokens
- **Dependency vulnerabilities** — known CVEs in project dependencies
- **Input validation** — unsanitized user input, missing boundary checks

## Findings and Severity

Each finding is classified by severity:

| Severity | Action |
|----------|--------|
| **CRITICAL** | Pipeline blocks. Auto-remediation attempted. |
| **HIGH** | Pipeline blocks (configurable via `SECURITY_BLOCK_SEVERITY`). Auto-remediation attempted. |
| **MEDIUM** | Logged to `NON_BLOCKING_LOG.md` as a non-blocking note. |
| **LOW** | Logged to `NON_BLOCKING_LOG.md`. |

When a blocking finding is detected, the pipeline enters a rework loop: the
security agent describes the issue, and a coder agent attempts to fix it. Up to
`SECURITY_MAX_REWORK_CYCLES` (default: 2) rework attempts are made.

## Configuration

```bash
# Toggle the security stage
SECURITY_AGENT_ENABLED=true

# Minimum severity to block the pipeline
SECURITY_BLOCK_SEVERITY=HIGH    # CRITICAL, HIGH, MEDIUM, or LOW

# Turn limits
SECURITY_MAX_TURNS=15
SECURITY_MIN_TURNS=8
SECURITY_MAX_TURNS_CAP=30

# Rework cycles for blocking findings
SECURITY_MAX_REWORK_CYCLES=2

# What to do with unfixable issues
SECURITY_UNFIXABLE_POLICY=escalate   # escalate, halt, or waiver

# Output files
SECURITY_REPORT_FILE=SECURITY_REPORT.md
SECURITY_NOTES_FILE=SECURITY_NOTES.md
```

## Skipping Security for a Run

For quick tasks where security review isn't needed:

```bash
tekhton --skip-security "Fix typo in README"
```

## Security Waivers

If a finding is a known accepted risk, create a waiver file:

```bash
SECURITY_WAIVER_FILE=.claude/security-waivers.md
```

Waived findings are noted in the report but don't block the pipeline.

## What's Next?

- [Security Configuration](security-config.md) — Detailed security setup guide
- [Pipeline Stages](../reference/stages.md) — Where security fits in the pipeline
- [Configuration Reference](../reference/configuration.md) — All security config keys
