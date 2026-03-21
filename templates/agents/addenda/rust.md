
## Rust Stack Notes

- Prefer `Result` and `?` operator over `.unwrap()` in library code.
- Use `clippy` lints as the quality baseline — `cargo clippy -- -D warnings`.
- Prefer owned types in public APIs; borrow in internal functions.
- Flag `unsafe` blocks for review — each must have a safety comment.
- Check for missing `#[derive(Debug)]` on public types.
