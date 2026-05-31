# Trivial scenario

Fixture for the rescan trivial-change path. The harness edits
src/main.go (an existing tracked file, NOT a manifest, NOT a config) —
the rescan should regen inventory + meta but leave tree / deps / configs
untouched.
