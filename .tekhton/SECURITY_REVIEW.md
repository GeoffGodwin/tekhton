## Summary
This change (m40.1) adds `AutoAdvance bool` and `AutoAdvanceLimit int` fields to the pipeline state snapshot struct and wires them through the bash writer, Go `applyField`/`lookupField` reflection layer, and resume path. The change is entirely internal to Tekhton's state-persistence subsystem with no external attack surface: no user-controlled input reaches the new fields except through the pipeline's own env-builder, the Go CLI is an operator tool (not a service), and both the bash and Go paths validate and sanitize values before use. No authentication, cryptography, network communication, or secret handling is involved.

## Findings
None

## Verdict
CLEAN
