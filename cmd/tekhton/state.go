package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strconv"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/state"
	"github.com/spf13/cobra"
)

// newStateCmd wires `tekhton state …` subcommands. The bash shim in
// lib/state.sh execs these instead of the heredoc + awk pair the V3 writer
// used; the on-disk JSON is the seam.
//
// Exit codes (callers depend on this):
//
//	0                — success (stdout = JSON or field value)
//	exitNotFound (1) — file missing (state.ErrNotFound or generic failure)
//	exitCorrupt  (2) — file corrupt (state.ErrCorrupt) — caller MUST NOT silent-retry
func newStateCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "state",
		Short: "Pipeline state snapshot — read, write, update, clear.",
	}
	c.AddCommand(newStateReadCmd(), newStateWriteCmd(), newStateUpdateCmd(), newStateClearCmd())
	return c
}

func newStateReadCmd() *cobra.Command {
	var (
		path  string
		field string
	)
	c := &cobra.Command{
		Use:   "read",
		Short: "Read the snapshot. Prints JSON, or with --field a single value.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path = resolveStatePath(path)
			if path == "" {
				return fmt.Errorf("state read: --path or $PIPELINE_STATE_FILE required")
			}
			snap, err := state.New(path).Read()
			if err != nil {
				if errors.Is(err, state.ErrNotFound) {
					return errExitCode{code: exitNotFound, err: err}
				}
				if errors.Is(err, state.ErrCorrupt) {
					return errExitCode{code: exitCorrupt, err: err}
				}
				return err
			}
			if field != "" {
				val := lookupField(snap, field)
				if val == "" {
					return errExitCode{code: exitNotFound, err: fmt.Errorf("field %q empty or absent", field)}
				}
				fmt.Println(val)
				return nil
			}
			data, err := snap.MarshalIndented()
			if err != nil {
				return err
			}
			fmt.Println(string(data))
			return nil
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $PIPELINE_STATE_FILE.")
	c.Flags().StringVar(&field, "field", "", "Print only this field's value (e.g. exit_stage).")
	return c
}

func newStateWriteCmd() *cobra.Command {
	var path string
	c := &cobra.Command{
		Use:   "write",
		Short: "Read JSON from stdin and atomically write it as the snapshot.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path = resolveStatePath(path)
			if path == "" {
				return fmt.Errorf("state write: --path or $PIPELINE_STATE_FILE required")
			}
			var snap proto.StateSnapshotV1
			dec := json.NewDecoder(os.Stdin)
			if err := dec.Decode(&snap); err != nil {
				return fmt.Errorf("state write: parse stdin: %w", err)
			}
			return state.New(path).Write(&snap)
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $PIPELINE_STATE_FILE.")
	return c
}

func newStateUpdateCmd() *cobra.Command {
	var (
		path   string
		fields []string
	)
	c := &cobra.Command{
		Use:   "update",
		Short: "Read-modify-write the snapshot. Each --field K=V mutates one field.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path = resolveStatePath(path)
			if path == "" {
				return fmt.Errorf("state update: --path or $PIPELINE_STATE_FILE required")
			}
			pairs, err := parseFieldPairs(fields)
			if err != nil {
				return err
			}
			return state.New(path).Update(func(s *proto.StateSnapshotV1) {
				for _, p := range pairs {
					applyField(s, p.key, p.val)
				}
			})
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $PIPELINE_STATE_FILE.")
	c.Flags().StringArrayVar(&fields, "field", nil, "Field assignment K=V (repeatable).")
	return c
}

func newStateClearCmd() *cobra.Command {
	var path string
	c := &cobra.Command{
		Use:   "clear",
		Short: "Remove the snapshot file. No error if absent.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path = resolveStatePath(path)
			if path == "" {
				return fmt.Errorf("state clear: --path or $PIPELINE_STATE_FILE required")
			}
			return state.New(path).Clear()
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $PIPELINE_STATE_FILE.")
	return c
}

type fieldPair struct{ key, val string }

func parseFieldPairs(fields []string) ([]fieldPair, error) {
	out := make([]fieldPair, 0, len(fields))
	for _, f := range fields {
		eq := strings.IndexByte(f, '=')
		if eq <= 0 {
			return nil, fmt.Errorf("state: --field expects K=V, got %q", f)
		}
		out = append(out, fieldPair{key: f[:eq], val: f[eq+1:]})
	}
	return out, nil
}

// applyField writes one K=V into the snapshot. First-class fields are matched
// by their JSON tag (case-insensitive); anything else lands in Extra so the
// V1.x forward-compat hatch absorbs unknown keys without losing them.
//
// Numeric first-class fields (review_cycle, pipeline_attempt, agent_calls_total)
// parse via strconv; parse failures fall through to Extra rather than
// erroring — bash callers may pass empty strings during partial updates and
// "best-effort write" is the contract the heredoc had.
func applyField(snap *proto.StateSnapshotV1, key, val string) {
	v := reflect.ValueOf(snap).Elem()
	t := v.Type()
	for i := 0; i < t.NumField(); i++ {
		tag := strings.Split(t.Field(i).Tag.Get("json"), ",")[0]
		if !strings.EqualFold(tag, key) {
			continue
		}
		fv := v.Field(i)
		switch fv.Kind() {
		case reflect.String:
			fv.SetString(val)
			return
		case reflect.Int, reflect.Int64:
			n, err := strconv.ParseInt(val, 10, 64)
			if err != nil {
				break
			}
			fv.SetInt(n)
			return
		}
	}
	if snap.Extra == nil {
		snap.Extra = make(map[string]string)
	}
	if val == "" {
		delete(snap.Extra, key)
		return
	}
	snap.Extra[key] = val
}

// lookupField is the read-side counterpart: resolves a field name (JSON tag,
// case-insensitive) against first-class fields, then falls through to Extra.
// Returns "" for unknown keys so bash callers can treat empty as absent.
func lookupField(snap *proto.StateSnapshotV1, key string) string {
	v := reflect.ValueOf(snap).Elem()
	t := v.Type()
	for i := 0; i < t.NumField(); i++ {
		tag := strings.Split(t.Field(i).Tag.Get("json"), ",")[0]
		if !strings.EqualFold(tag, key) {
			continue
		}
		fv := v.Field(i)
		switch fv.Kind() {
		case reflect.String:
			return fv.String()
		case reflect.Int, reflect.Int64:
			n := fv.Int()
			if n == 0 {
				return ""
			}
			return strconv.FormatInt(n, 10)
		}
	}
	if snap.Extra != nil {
		if val, ok := snap.Extra[key]; ok {
			return val
		}
	}
	return ""
}

func resolveStatePath(path string) string {
	if path != "" {
		return path
	}
	return os.Getenv("PIPELINE_STATE_FILE")
}
