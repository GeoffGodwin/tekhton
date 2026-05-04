package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/causal"
	"github.com/spf13/cobra"
)

// newCausalCmd wires `tekhton causal …` subcommands. The bash shim in
// lib/causality.sh execs these instead of carrying its own JSON-builder
// logic; the on-disk format is the seam.
func newCausalCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "causal",
		Short: "Causal event log writer (init, emit, archive, status).",
	}
	c.AddCommand(newCausalInitCmd(), newCausalEmitCmd(), newCausalArchiveCmd(), newCausalStatusCmd())
	return c
}

func newCausalInitCmd() *cobra.Command {
	var (
		path  string
		cap   int
		runID string
	)
	c := &cobra.Command{
		Use:   "init",
		Short: "Ensure the causal log file and its archive directory exist.",
		Long: "init creates the parent directories and touches the log file if missing.\n" +
			"It does NOT truncate an existing log — that would clobber resumed runs.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if path == "" {
				return fmt.Errorf("causal init: --path is required")
			}
			if _, err := causal.Open(path, cap, runID); err != nil {
				return err
			}
			// Touch the log file so subsequent shell tests for `[ -f ]` succeed.
			f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE, 0o644)
			if err != nil {
				return fmt.Errorf("causal init: touch: %w", err)
			}
			return f.Close()
		},
	}
	c.Flags().StringVar(&path, "path", "", "Path to CAUSAL_LOG.jsonl.")
	c.Flags().IntVar(&cap, "cap", 2000, "Max events per run before eviction.")
	c.Flags().StringVar(&runID, "run-id", "", "Run identifier for archive naming.")
	return c
}

func newCausalEmitCmd() *cobra.Command {
	var (
		path      string
		cap       int
		runID     string
		stage     string
		evType    string
		detail    string
		milestone string
		causedBy  []string
		verdict   string
		context   string
	)
	c := &cobra.Command{
		Use:   "emit",
		Short: "Append one event to the causal log; prints the assigned ID on stdout.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if path == "" {
				path = os.Getenv("CAUSAL_LOG_FILE")
			}
			if path == "" {
				return fmt.Errorf("causal emit: --path or $CAUSAL_LOG_FILE required")
			}
			l, err := causal.Open(path, cap, runID)
			if err != nil {
				return err
			}
			defer l.Close()
			in := causal.EmitInput{
				Stage:     stage,
				Type:      evType,
				Detail:    detail,
				Milestone: milestone,
				CausedBy:  causedBy,
			}
			if verdict != "" {
				in.Verdict = json.RawMessage(verdict)
			}
			if context != "" {
				in.Context = json.RawMessage(context)
			}
			id, err := l.Emit(in)
			if err != nil {
				return err
			}
			fmt.Println(id)
			return nil
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $CAUSAL_LOG_FILE.")
	c.Flags().IntVar(&cap, "cap", envIntDefault("CAUSAL_LOG_MAX_EVENTS", 2000), "Max events before eviction.")
	c.Flags().StringVar(&runID, "run-id", os.Getenv("RUN_ID"), "Run identifier (defaults to $RUN_ID).")
	c.Flags().StringVar(&stage, "stage", "", "Stage name (required).")
	c.Flags().StringVar(&evType, "type", "", "Event type (required).")
	c.Flags().StringVar(&detail, "detail", "", "Free-form detail string.")
	c.Flags().StringVar(&milestone, "milestone", os.Getenv("_CURRENT_MILESTONE"), "Current milestone ID.")
	c.Flags().StringSliceVar(&causedBy, "caused-by", nil, "Upstream event ID (repeatable).")
	c.Flags().StringVar(&verdict, "verdict", "", "Pre-formatted JSON verdict, or empty for null.")
	c.Flags().StringVar(&context, "context", "", "Pre-formatted JSON context, or empty for null.")
	return c
}

func newCausalArchiveCmd() *cobra.Command {
	var (
		path      string
		runID     string
		retention int
	)
	c := &cobra.Command{
		Use:   "archive",
		Short: "Copy the causal log into runs/ and prune old archives.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if path == "" {
				path = os.Getenv("CAUSAL_LOG_FILE")
			}
			if path == "" {
				return fmt.Errorf("causal archive: --path or $CAUSAL_LOG_FILE required")
			}
			l, err := causal.Open(path, 0, runID)
			if err != nil {
				return err
			}
			defer l.Close()
			return l.Archive(retention)
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $CAUSAL_LOG_FILE.")
	c.Flags().StringVar(&runID, "run-id", os.Getenv("RUN_ID"), "Run identifier (drives archive filename).")
	c.Flags().IntVar(&retention, "retention", envIntDefault("CAUSAL_LOG_RETENTION_RUNS", 50), "Max archived runs to keep.")
	return c
}

func newCausalStatusCmd() *cobra.Command {
	var path string
	c := &cobra.Command{
		Use:   "status",
		Short: "Print the most recent event ID seen on disk (one line).",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if path == "" {
				path = os.Getenv("CAUSAL_LOG_FILE")
			}
			if path == "" {
				return fmt.Errorf("causal status: --path or $CAUSAL_LOG_FILE required")
			}
			id, err := lastEventID(path)
			if err != nil {
				return err
			}
			fmt.Println(id)
			return nil
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $CAUSAL_LOG_FILE.")
	return c
}

// lastEventID scans the log file and returns the id field of the last line.
// The log is bounded by CAUSAL_LOG_MAX_EVENTS so a full scan is cheap.
func lastEventID(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	var last string
	for sc.Scan() {
		line := sc.Text()
		if line == "" {
			continue
		}
		const key = `"id":"`
		idx := strings.Index(line, key)
		if idx < 0 {
			continue
		}
		rest := line[idx+len(key):]
		end := strings.IndexByte(rest, '"')
		if end < 0 {
			continue
		}
		last = rest[:end]
	}
	return last, sc.Err()
}

func envIntDefault(name string, def int) int {
	if v := os.Getenv(name); v != "" {
		var n int
		if _, err := fmt.Sscanf(v, "%d", &n); err == nil {
			return n
		}
	}
	return def
}
