# testdata/causal/ — Golden fixtures for the causal log writer

These fixtures pin the on-disk shape of a `causal.event.v1` JSONL line so
both the Go writer (`internal/causal`) and the bash fallback in
`lib/causality.sh` are unit-tested against the same expected bytes.

## Files

- `event_minimal.golden.jsonl` — one event with no caused-by, verdict, or
  context. Establishes the field order, escape rules, and `null` literals.
- `event_full.golden.jsonl` — one event with multi-element caused-by, a
  pre-formatted JSON verdict, and a JSON context object. Exercises every
  optional field in the envelope.

The `ts` field in each fixture is the literal placeholder
`__TS_PLACEHOLDER__`. Tests substitute or strip the timestamp before
comparing — see `scripts/causal-parity-check.sh` for the masking rules.

## Updating

Regenerate by running the fixture script in
`scripts/causal-parity-check.sh` against the current writer and replacing
the actual `ts` value with the placeholder. Any other change to the file
shape requires a milestone-level review (the bash query layer assumes this
contract is stable).
