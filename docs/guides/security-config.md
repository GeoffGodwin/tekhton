# Security Configuration

Tekhton includes a dedicated security review stage that checks your code for
vulnerabilities. Here's how to configure it.

## Overview

The security agent runs after the coder stage and before the code reviewer. It
scans for:

- OWASP Top 10 vulnerabilities
- Hardcoded secrets and credentials
- Dependency vulnerabilities
- Insecure configuration patterns
- Input validation issues

## Severity Levels

Findings are rated by severity:

| Severity | Meaning | Default Action |
|----------|---------|---------------|
| CRITICAL | Exploitable vulnerability, immediate risk | Blocks pipeline |
| HIGH | Significant security risk | Blocks pipeline |
| MEDIUM | Moderate risk, should be addressed | Reported, doesn't block |
| LOW | Minor concern, best practice | Reported, doesn't block |
| INFORMATIONAL | Suggestion for improvement | Reported, doesn't block |

## Configuration Options

### Block Severity

Control which severity levels block the pipeline:

```bash
# In pipeline.conf
SECURITY_BLOCK_SEVERITY="HIGH"    # Block on HIGH and CRITICAL (default)
```

Set to `CRITICAL` to only block on critical findings, or `MEDIUM` to be stricter.

### Unfixable Issues Policy

When the security agent finds something it can't fix automatically:

```bash
SECURITY_UNFIXABLE_POLICY="escalate"   # Default: escalate to human
# Options: escalate, warn, pass
```

- **`escalate`** — Adds the issue to `HUMAN_ACTION_REQUIRED.md` and blocks
- **`warn`** — Reports the issue but doesn't block
- **`pass`** — Silently passes (not recommended)

### Security Waivers

For known issues that you've accepted the risk on:

```bash
SECURITY_WAIVER_FILE=".claude/security-waivers.md"
```

Create the waiver file with entries like:

```markdown
## Waived Issues

- **CVE-2024-1234**: Accepted risk — not exploitable in our deployment context.
  Approved by: Jane Doe, 2024-11-15
- **Hardcoded test credentials in tests/**: Test-only credentials, not used in
  production.
```

### Offline Mode

By default, the security agent works offline (analyzing code without making
network calls). Configure online vulnerability checking:

```bash
SECURITY_OFFLINE_MODE="auto"           # Default: auto-detect
SECURITY_ONLINE_SOURCES=""             # Optional: specific sources
```

### Skipping Security Review

For tasks where security review isn't needed (documentation changes, config
tweaks):

```bash
tekhton --skip-security "Update the README"
```

## Reading the Security Report

After a run, check `SECURITY_REPORT.md` for:

- **Finding summary** — Count by severity
- **Detailed findings** — Each issue with location, description, and remediation
- **Remediation status** — Whether the agent fixed it or escalated it
- **Waiver matches** — Which findings matched existing waivers

## Customizing the Security Agent

Edit `.claude/agents/security.md` to customize the security agent's behavior:

- Add project-specific security rules
- Define your threat model
- Specify which patterns are acceptable in your context

## What's Next?

- [Configuration Reference](../reference/configuration.md) — All security config keys
- [Agent Roles](../reference/agents.md) — Customizing agent behavior
- [Troubleshooting](../troubleshooting/common-errors.md) — Common security-related errors
