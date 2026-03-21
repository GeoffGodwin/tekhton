
## Python Stack Notes

- Follow PEP 8 style conventions. Prefer type hints on all public function signatures.
- Use `pathlib.Path` over `os.path` for file operations.
- Prefer dataclasses or Pydantic models over plain dicts for structured data.
- Flag bare `except:` clauses — always catch specific exception types.
- Check for missing `__init__.py` files in package directories.
