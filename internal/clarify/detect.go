// Package clarify is the m25 Go port of lib/clarify.sh — the
// mid-pipeline clarification protocol that lets agents pause for
// blocking human input via CLARIFICATIONS.md.
//
// Two pieces:
//
//   - detect.go: parse a report file for `## Clarification Required`
//     items tagged [BLOCKING] / [NON_BLOCKING], and load
//     CLARIFICATIONS.md into a template variable.
//   - handle.go: prompt the human for answers and write them to
//     CLARIFICATIONS.md (or poll for an external file edit when the
//     pipeline is non-interactive — the dashboard path).
package clarify

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// Sentinel errors callers match with errors.Is.
var (
	// ErrNoClarifications is returned by DetectFromFile when the
	// report does not contain a "## Clarification Required" section
	// or the section is empty.
	ErrNoClarifications = errors.New("clarify: no clarifications found")

	// ErrDisabled is returned when clarification handling has been
	// turned off via the CLARIFICATION_ENABLED env var.
	ErrDisabled = errors.New("clarify: clarification handling disabled")
)

// Item is one clarification entry parsed from the report.
type Item struct {
	// Question is the body of the item with the leading "- "
	// markdown bullet stripped.
	Question string
	// Blocking is true when the item was tagged [BLOCKING], false
	// for [NON_BLOCKING].
	Blocking bool
}

// Items is a parsed clarification list.
type Items struct {
	Blocking    []Item
	NonBlocking []Item
}

// HasBlocking reports whether any blocking items were found.
func (i *Items) HasBlocking() bool { return len(i.Blocking) > 0 }

// HasAny reports whether any items (blocking or non-blocking) exist.
func (i *Items) HasAny() bool { return i.HasBlocking() || len(i.NonBlocking) > 0 }

// DetectOptions controls the parser. Tests substitute the env
// reader to flip CLARIFICATION_ENABLED without touching the process
// environment.
type DetectOptions struct {
	// Env returns the value of an environment variable. Defaults to
	// os.Getenv when nil.
	Env func(key string) string
}

// DetectFromFile reads a report file and returns its clarification
// items. Returns ErrNoClarifications when the section is absent or
// empty. Returns ErrDisabled when CLARIFICATION_ENABLED is set to a
// non-"true" value.
func DetectFromFile(path string, opts DetectOptions) (*Items, error) {
	if opts.Env == nil {
		opts.Env = os.Getenv
	}
	enabled := opts.Env("CLARIFICATION_ENABLED")
	if enabled != "" && enabled != "true" {
		return nil, ErrDisabled
	}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNoClarifications
		}
		return nil, err
	}
	defer f.Close()
	return parseClarifications(f)
}

// parseClarifications scans the input for a "## Clarification
// Required" section and returns the items inside it. The section
// ends at the next "## " heading or EOF.
func parseClarifications(r interface{ Read(p []byte) (int, error) }) (*Items, error) {
	var (
		inSection bool
		items     = &Items{}
	)
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := sc.Text()
		if !inSection {
			if strings.HasPrefix(line, "## Clarification Required") {
				inSection = true
			}
			continue
		}
		// In section — exit on the next H2 heading.
		if strings.HasPrefix(line, "## ") {
			break
		}
		body := strings.TrimSpace(line)
		if body == "" {
			continue
		}
		// Bullets are "- ..."; only consider those.
		if !strings.HasPrefix(body, "- ") {
			continue
		}
		body = strings.TrimPrefix(body, "- ")
		switch {
		case containsTag(body, "BLOCKING"):
			items.Blocking = append(items.Blocking, Item{Question: body, Blocking: true})
		case containsTag(body, "NON_BLOCKING"):
			items.NonBlocking = append(items.NonBlocking, Item{Question: body, Blocking: false})
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if !items.HasAny() {
		return nil, ErrNoClarifications
	}
	return items, nil
}

// containsTag matches `[TAG]` in the item body case-insensitively.
// The bash version used `grep -i` so the tag's case in the source
// document doesn't matter. The NON_BLOCKING tag must be checked
// before BLOCKING (it contains the substring "BLOCKING") — callers
// using the switch above already do this implicitly.
func containsTag(body, tag string) bool {
	if tag == "BLOCKING" {
		// A bare BLOCKING tag must NOT be present in a NON_BLOCKING line.
		if containsTag(body, "NON_BLOCKING") {
			return false
		}
	}
	return strings.Contains(strings.ToUpper(body), "["+tag+"]")
}

// LoadFileContent reads CLARIFICATIONS.md for template injection.
// Returns an empty string when the file is missing or empty —
// callers expect the empty string as the "no clarifications" state.
// The 1 MiB cap matches the bash _safe_read_file convention.
func LoadFileContent(path string) (string, error) {
	st, err := os.Stat(path)
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	const maxBytes = 1 << 20
	size := st.Size()
	if size > maxBytes {
		size = maxBytes
	}
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	buf := make([]byte, size)
	n, err := f.Read(buf)
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	body := string(buf[:n])
	if st.Size() > maxBytes {
		body += fmt.Sprintf("\n... (truncated, original size %d bytes)\n", st.Size())
	}
	return body, nil
}
