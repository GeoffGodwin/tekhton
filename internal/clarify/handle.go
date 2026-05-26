package clarify

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

// ErrAborted is returned by HandleInteractive when the user types
// "abort" at the answer prompt.
var ErrAborted = errors.New("clarify: aborted by user")

// HandleOptions configures the interactive handler.
type HandleOptions struct {
	// Input is the source the handler reads answers from. Defaults
	// to opening /dev/tty when nil.
	Input io.Reader
	// Output is where the handler writes prompts. Defaults to
	// os.Stderr so prompts do not pollute pipeline stdout.
	Output io.Writer
	// ClarificationsPath is the file appended with question/answer
	// pairs. Must be set — there is no useful default.
	ClarificationsPath string
	// Now provides the timestamp used in the section header.
	// Defaults to time.Now.
	Now func() time.Time
}

// HandleInteractive prompts the user for an answer to each blocking
// item, writes the Q/A pairs to ClarificationsPath, and returns nil
// on success. Non-blocking items are logged-only (no prompt).
//
// Returns ErrAborted if the user types "abort". The caller persists
// any partial answers — this function appends to the file as each
// answer is collected, so the on-disk file is always up to date.
func HandleInteractive(items *Items, opts HandleOptions) error {
	if items == nil || !items.HasBlocking() {
		// Non-blocking only — log to Output and return.
		if items != nil {
			for _, n := range items.NonBlocking {
				fmt.Fprintf(orStderr(opts.Output),
					"clarify: non-blocking: %s\n", n.Question)
			}
		}
		return nil
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}
	if opts.ClarificationsPath == "" {
		return errors.New("clarify: ClarificationsPath required")
	}
	in := opts.Input
	if in == nil {
		tty, err := os.Open("/dev/tty")
		if err != nil {
			return fmt.Errorf("clarify: /dev/tty unavailable: %w", err)
		}
		defer tty.Close()
		in = tty
	}
	out := orStderr(opts.Output)

	// Write the section header for this round.
	header := fmt.Sprintf("# Clarifications — %s\n\n", opts.Now().Format("2006-01-02 15:04:05"))
	if err := appendOrCreate(opts.ClarificationsPath, header); err != nil {
		return err
	}

	br := bufio.NewReader(in)
	for i, q := range items.Blocking {
		fmt.Fprintf(out, "\nQuestion %d/%d\n", i+1, len(items.Blocking))
		fmt.Fprintf(out, "  %s\n\n", q.Question)
		fmt.Fprintf(out, "  Answer: ")
		ans, err := br.ReadString('\n')
		if err != nil && !errors.Is(err, io.EOF) {
			return err
		}
		ans = strings.TrimRight(ans, "\r\n")
		switch ans {
		case "abort":
			return ErrAborted
		case "skip":
			if err := appendOrCreate(opts.ClarificationsPath,
				fmt.Sprintf("## Q: %s\n**A:** (skipped by user)\n\n", q.Question)); err != nil {
				return err
			}
		default:
			if err := appendOrCreate(opts.ClarificationsPath,
				fmt.Sprintf("## Q: %s\n**A:** %s\n\n", q.Question, ans)); err != nil {
				return err
			}
		}
	}
	return nil
}

// PollUntilAnswered watches ClarificationsPath for unchecked
// questions and returns nil when all blocking items in `items` have
// a non-empty answer recorded. Used by non-interactive contexts
// (dashboard, CI) where the human edits the file directly.
//
// The poll cadence matches the bash version's 5-second tick — but
// uses time.NewTicker so context cancellation is responsive (the
// bash version's sleep 5 could leave a Ctrl-C waiting up to five
// seconds for the next iteration).
func PollUntilAnswered(ctx context.Context, items *Items, path string, interval time.Duration) error {
	if items == nil || !items.HasBlocking() {
		return nil
	}
	if interval <= 0 {
		interval = 5 * time.Second
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		answered, err := allAnswered(items, path)
		if err != nil {
			return err
		}
		if answered {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
		}
	}
}

// allAnswered returns true when every blocking item in items has a
// non-empty `**A:**` line in the file at path.
func allAnswered(items *Items, path string) (bool, error) {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer f.Close()
	answers := make(map[string]string)
	var currentQ string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "## Q: ") {
			currentQ = strings.TrimSpace(strings.TrimPrefix(line, "## Q: "))
			continue
		}
		if currentQ != "" && strings.HasPrefix(line, "**A:**") {
			ans := strings.TrimSpace(strings.TrimPrefix(line, "**A:**"))
			answers[currentQ] = ans
			currentQ = ""
		}
	}
	if err := sc.Err(); err != nil {
		return false, err
	}
	for _, b := range items.Blocking {
		if answers[b.Question] == "" {
			return false, nil
		}
	}
	return true, nil
}

// ClearStaleEntries removes CLARIFICATIONS.md when the file exists
// and every recorded section is fully answered. Mirrors the new
// finalize-time cleanup hook m25 adds: stale state from a prior
// pause shouldn't leak into the next pipeline run. Returns true
// when the file was removed.
func ClearStaleEntries(path string) (bool, error) {
	st, err := os.Stat(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if st.Size() == 0 {
		// Empty file — remove it.
		return true, os.Remove(path)
	}
	// We only clear when every Q has an A. Conservative — leaves
	// partially-answered sessions in place for the next run to
	// resume.
	body, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	lines := strings.Split(string(body), "\n")
	pending := 0
	for i, line := range lines {
		if !strings.HasPrefix(line, "## Q: ") {
			continue
		}
		// Look ahead for the next `**A:**` line.
		answered := false
		for j := i + 1; j < len(lines) && !strings.HasPrefix(lines[j], "## Q: "); j++ {
			if strings.HasPrefix(lines[j], "**A:**") {
				if strings.TrimSpace(strings.TrimPrefix(lines[j], "**A:**")) != "" {
					answered = true
				}
				break
			}
		}
		if !answered {
			pending++
		}
	}
	if pending > 0 {
		return false, nil
	}
	return true, os.Remove(path)
}

// appendOrCreate appends s to path, creating the file if missing.
func appendOrCreate(path, s string) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(s)
	return err
}

func orStderr(w io.Writer) io.Writer {
	if w != nil {
		return w
	}
	return os.Stderr
}
