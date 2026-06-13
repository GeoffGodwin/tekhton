<!-- milestone-meta
id: "1"
status: "todo"
-->

# m01 — Create Hello File

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Fixture for zero-claude e2e test (m23) |
| **Gap** | No hello.txt in the project |
| **m01 fills** | Creates hello.txt with content "hello" |
| **Depends on** | — |
| **Files changed** | `hello.txt` |

---

## Design

Create a file named `hello.txt` in the project root with the single line "hello".

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `hello.txt` | Create | Single-line file with content "hello" |

---

## Acceptance Criteria

- [ ] `hello.txt` exists in the project root.
- [ ] `hello.txt` contains the text "hello".

## Watch For

- The file must be created in the working directory (project root).

## Seeds Forward

- Used as the verification artifact in the m23 zero-claude e2e test.
