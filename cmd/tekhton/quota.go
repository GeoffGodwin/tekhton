package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/geoffgodwin/tekhton/internal/supervisor"
	"github.com/spf13/cobra"
)

// newQuotaCmd wires `tekhton quota …` subcommands. The subcommands are
// diagnostic-grade — `status` reads the most recent quota events from the
// causal log so operators can tell whether a pause is currently active,
// and `probe` runs a single layered probe against the configured agent
// binary so an operator can sanity-check whether the upstream is back.
//
// Production quota handling stays in `lib/quota.sh` until m10 lands the
// parity test and flips the bash supervisor; this CLI exists so the
// parity test has a Go-side surface to compare against and so the V4
// supervisor's quota module is exercisable by humans during cut-over.
func newQuotaCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "quota",
		Short: "Quota pause/probe diagnostic commands.",
	}
	c.AddCommand(newQuotaStatusCmd(), newQuotaProbeCmd())
	return c
}

// newQuotaStatusCmd implements `tekhton quota status`. Walks the causal log
// in reverse, finds the most recent quota_pause / quota_resume / quota_probe
// event, and renders a one-line summary plus a JSON envelope for machines.
func newQuotaStatusCmd() *cobra.Command {
	var (
		path string
		raw  bool
	)
	c := &cobra.Command{
		Use:   "status",
		Short: "Print the most recent quota pause state from the causal log.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if path == "" {
				path = os.Getenv("CAUSAL_LOG_FILE")
			}
			if path == "" {
				return fmt.Errorf("quota status: --path or $CAUSAL_LOG_FILE required")
			}
			st, err := readQuotaStatus(path)
			if err != nil {
				return err
			}
			if raw {
				data, err := json.MarshalIndent(st, "", "  ")
				if err != nil {
					return err
				}
				fmt.Fprintln(cmd.OutOrStdout(), string(data))
				return nil
			}
			fmt.Fprintln(cmd.OutOrStdout(), st.Human())
			return nil
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $CAUSAL_LOG_FILE.")
	c.Flags().BoolVar(&raw, "json", false, "Emit JSON instead of the human one-liner.")
	return c
}

// newQuotaProbeCmd implements `tekhton quota probe`. Runs one probe and
// prints active / lifted / error. Used by m10's parity test and by humans
// debugging quota state — never invoked from production hot paths.
func newQuotaProbeCmd() *cobra.Command {
	var (
		kindFlag string
		timeout  time.Duration
	)
	c := &cobra.Command{
		Use:   "probe",
		Short: "Run a single quota probe and print the result (active|lifted|error).",
		RunE: func(cmd *cobra.Command, _ []string) error {
			kind, err := parseProbeKind(kindFlag)
			if err != nil {
				return errExitCode{code: exitUsage, err: err}
			}
			ctx, cancel := context.WithTimeout(cmd.Context(), timeout)
			defer cancel()
			sup := supervisor.New(nil, nil)
			result := sup.Probe(ctx, kind)
			fmt.Fprintln(cmd.OutOrStdout(), result.String())
			if result == supervisor.ProbeError {
				return errExitCode{code: exitSoftware, err: fmt.Errorf("probe error")}
			}
			return nil
		},
	}
	c.Flags().StringVar(&kindFlag, "kind", "version", "Probe kind: version | zero-turn | fallback.")
	c.Flags().DurationVar(&timeout, "timeout", 30*time.Second, "Per-probe timeout.")
	return c
}

// parseProbeKind maps the CLI string to the typed enum. Accepts both the
// dash form (zero-turn) and the V3 underscore form (zero_turn) since both
// appear in operator scripts.
func parseProbeKind(s string) (supervisor.ProbeKind, error) {
	switch strings.ToLower(s) {
	case "version":
		return supervisor.ProbeVersion, nil
	case "zero-turn", "zero_turn":
		return supervisor.ProbeZeroTurn, nil
	case "fallback":
		return supervisor.ProbeFallback, nil
	}
	return 0, fmt.Errorf("invalid --kind %q (want: version|zero-turn|fallback)", s)
}

// quotaStatus is the shape `quota status --json` emits. Plain JSON so a
// dashboard or shell test can consume it without growing a bespoke parser.
type quotaStatus struct {
	Paused        bool   `json:"paused"`
	Reason        string `json:"reason,omitempty"`
	LastEventID   string `json:"last_event_id,omitempty"`
	LastEventType string `json:"last_event_type,omitempty"`
	LastDetail    string `json:"last_detail,omitempty"`
}

// Human renders the one-line summary for `quota status` (no flag). Matches
// the bash side's convention: "paused: <reason>" / "active".
func (q quotaStatus) Human() string {
	if q.Paused {
		if q.Reason != "" {
			return "paused: " + q.Reason
		}
		return "paused"
	}
	return "active"
}

// readQuotaStatus walks the causal log finding the most recent quota_*
// event. quota_pause without a subsequent quota_resume → currently paused.
// Logs the event id and detail so operators can grep the line directly.
func readQuotaStatus(path string) (quotaStatus, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return quotaStatus{}, nil
		}
		return quotaStatus{}, err
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	var (
		st         quotaStatus
		lastPause  quotaLineFields
		lastResume quotaLineFields
		lineNo     int
	)
	for sc.Scan() {
		line := sc.Text()
		if line == "" {
			continue
		}
		lineNo++
		fields, ok := parseQuotaEventLine(line, lineNo)
		if !ok {
			continue
		}
		switch fields.eventType {
		case "quota_pause":
			lastPause = fields
		case "quota_resume":
			lastResume = fields
		}
	}
	if err := sc.Err(); err != nil {
		return quotaStatus{}, err
	}

	// "Currently paused" iff a quota_pause is more recent than any
	// quota_resume. Compare on the line-position implicit in scanner
	// order — the JSONL file is monotonic, so later wins.
	if lastPause.eventID != "" && lastPause.lineNo > lastResume.lineNo {
		st.Paused = true
		st.Reason = lastPause.reason
		st.LastEventID = lastPause.eventID
		st.LastEventType = "quota_pause"
		st.LastDetail = lastPause.detail
	} else if lastResume.eventID != "" {
		st.LastEventID = lastResume.eventID
		st.LastEventType = "quota_resume"
		st.LastDetail = lastResume.detail
	}
	return st, nil
}

// quotaLineFields captures the bits of a JSONL event line the status reader
// cares about. lineNo is a monotonic sequence the scanner increments so we
// can compare relative ordering of quota_pause vs quota_resume without
// re-parsing timestamps.
type quotaLineFields struct {
	lineNo    int
	eventID   string
	eventType string
	reason    string
	detail    string
}

// parseQuotaEventLine returns the quota-event-shaped subset of one JSONL
// line. Non-quota events return ok=false so the reader can skip them
// cheaply without a full unmarshal.
func parseQuotaEventLine(line string, lineNo int) (quotaLineFields, bool) {
	var raw map[string]any
	if err := json.Unmarshal([]byte(line), &raw); err != nil {
		return quotaLineFields{}, false
	}
	t, _ := raw["type"].(string)
	if !strings.HasPrefix(t, "quota_") {
		return quotaLineFields{}, false
	}
	id, _ := raw["id"].(string)
	detail, _ := raw["detail"].(string)

	// detail is "<reason>\t<body>" — split once.
	reason := ""
	body := detail
	if i := strings.IndexByte(detail, '\t'); i > 0 {
		reason = detail[:i]
		body = detail[i+1:]
	}
	return quotaLineFields{
		lineNo:    lineNo,
		eventID:   id,
		eventType: t,
		reason:    reason,
		detail:    body,
	}, true
}
