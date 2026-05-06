package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/manifest"
	"github.com/spf13/cobra"
)

// newManifestCmd wires `tekhton manifest …` subcommands. The bash shim in
// lib/milestone_dag_io.sh execs these instead of parsing MANIFEST.cfg via
// awk + sed; the on-disk CSV-with-#comments format is the seam.
//
// Exit codes:
//
//	0                — success (stdout = pipe-delimited rows or JSON)
//	exitNotFound (1) — manifest file missing or empty (no entries)
//	exitUsage   (64) — caller-side argument or field error
//	exitCorrupt  (2) — manifest file present but unparseable
func newManifestCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "manifest",
		Short: "Milestone MANIFEST.cfg — list, get, set-status, frontier.",
	}
	c.AddCommand(newManifestListCmd(), newManifestGetCmd(), newManifestSetStatusCmd(), newManifestFrontierCmd())
	return c
}

func newManifestListCmd() *cobra.Command {
	var (
		path   string
		asJSON bool
	)
	c := &cobra.Command{
		Use:   "list",
		Short: "Print all manifest entries in load order.",
		Long: "By default emits one line per entry in the legacy " +
			"id|title|status|depends|file|parallel_group format — matching " +
			"what bash arrays see after load_manifest. With --json emits a " +
			"tekhton.manifest.v1 envelope.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path = resolveManifestPath(path)
			if path == "" {
				return fmt.Errorf("manifest list: --path or $MILESTONE_MANIFEST_FILE required")
			}
			m, err := loadOrExit(path)
			if err != nil {
				return err
			}
			if asJSON {
				data, err := json.MarshalIndent(m.ToProto(), "", "  ")
				if err != nil {
					return err
				}
				fmt.Println(string(data))
				return nil
			}
			for _, e := range m.Entries {
				fmt.Println(formatEntryLine(e))
			}
			return nil
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $MILESTONE_MANIFEST_FILE.")
	c.Flags().BoolVar(&asJSON, "json", false, "Emit tekhton.manifest.v1 JSON envelope instead of pipe-delimited rows.")
	return c
}

func newManifestGetCmd() *cobra.Command {
	var (
		path  string
		field string
	)
	c := &cobra.Command{
		Use:   "get <id>",
		Short: "Print a single entry. With --field, print just that field's value.",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			path = resolveManifestPath(path)
			if path == "" {
				return fmt.Errorf("manifest get: --path or $MILESTONE_MANIFEST_FILE required")
			}
			m, err := loadOrExit(path)
			if err != nil {
				return err
			}
			e, ok := m.Get(args[0])
			if !ok {
				return errExitCode{code: exitNotFound, err: fmt.Errorf("unknown id %q", args[0])}
			}
			if field == "" {
				fmt.Println(formatEntryLine(e))
				return nil
			}
			val := lookupEntryField(e, field)
			if val == "" {
				return errExitCode{code: exitNotFound, err: fmt.Errorf("field %q empty or unknown", field)}
			}
			fmt.Println(val)
			return nil
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $MILESTONE_MANIFEST_FILE.")
	c.Flags().StringVar(&field, "field", "", "Print only this field (id, title, status, depends, file, group).")
	return c
}

func newManifestSetStatusCmd() *cobra.Command {
	var path string
	c := &cobra.Command{
		Use:   "set-status <id> <status>",
		Short: "Atomically update one milestone's status.",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			path = resolveManifestPath(path)
			if path == "" {
				return fmt.Errorf("manifest set-status: --path or $MILESTONE_MANIFEST_FILE required")
			}
			m, err := manifest.Load(path)
			if err != nil {
				return mapManifestError(err)
			}
			if err := m.SetStatus(args[0], args[1]); err != nil {
				if errors.Is(err, manifest.ErrUnknownID) {
					return errExitCode{code: exitNotFound, err: err}
				}
				if errors.Is(err, manifest.ErrInvalidField) {
					return errExitCode{code: exitUsage, err: err}
				}
				return err
			}
			return m.Save()
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $MILESTONE_MANIFEST_FILE.")
	return c
}

func newManifestFrontierCmd() *cobra.Command {
	var path string
	c := &cobra.Command{
		Use:   "frontier",
		Short: "Print IDs of milestones whose deps are satisfied and whose status is actionable.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path = resolveManifestPath(path)
			if path == "" {
				return fmt.Errorf("manifest frontier: --path or $MILESTONE_MANIFEST_FILE required")
			}
			m, err := loadOrExit(path)
			if err != nil {
				return err
			}
			for _, e := range m.Frontier() {
				fmt.Println(e.ID)
			}
			return nil
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $MILESTONE_MANIFEST_FILE.")
	return c
}

// resolveManifestPath: --path > env > "" (caller errors).
func resolveManifestPath(path string) string {
	if path != "" {
		return path
	}
	return os.Getenv("MILESTONE_MANIFEST_FILE")
}

// loadOrExit wraps manifest.Load with the standard exit-code error mapping.
func loadOrExit(path string) (*manifest.Manifest, error) {
	m, err := manifest.Load(path)
	if err != nil {
		return nil, mapManifestError(err)
	}
	return m, nil
}

func mapManifestError(err error) error {
	switch {
	case errors.Is(err, manifest.ErrNotFound), errors.Is(err, manifest.ErrEmpty):
		return errExitCode{code: exitNotFound, err: err}
	case errors.Is(err, manifest.ErrInvalidField):
		return errExitCode{code: exitCorrupt, err: err}
	default:
		return err
	}
}

// formatEntryLine serializes one entry to the same pipe-delimited shape the
// bash parallel arrays expose when iterated. The parity script diffs this
// output against the bash dump for fixture-by-fixture equivalence.
func formatEntryLine(e *manifest.Entry) string {
	return e.ID + "|" + e.Title + "|" + e.Status + "|" + strings.Join(e.Depends, ",") + "|" + e.File + "|" + e.Group
}

// lookupEntryField resolves a field name (case-insensitive) for `manifest get
// --field`. Returns "" for unknown keys so bash callers can treat empty as
// absent (matching `state read --field`).
func lookupEntryField(e *manifest.Entry, key string) string {
	switch strings.ToLower(key) {
	case "id":
		return e.ID
	case "title":
		return e.Title
	case "status":
		return e.Status
	case "depends", "depends_on":
		return strings.Join(e.Depends, ",")
	case "file":
		return e.File
	case "group", "parallel_group":
		return e.Group
	}
	return ""
}
