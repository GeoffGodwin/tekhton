
## Go Stack Notes

- Follow standard Go conventions: `gofmt`, `go vet`, short variable names in small scopes.
- Prefer returning errors over panicking. Check every error return.
- Use table-driven tests as the default testing pattern.
- Prefer interfaces at the consumer, not the producer.
- Flag exported names that don't have godoc comments.
