package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
	"github.com/spf13/cobra"
)

// newSuperviseCmd wires `tekhton supervise`. The subcommand reads an
// agent.request.v1 JSON envelope (from --request-file or stdin), hands it
// to internal/supervisor.Retry (m10 default) or .Run (with --no-retry), and
// prints an agent.response.v1 JSON envelope on stdout. Exit code semantics:
//
//	0          — supervisor ran the agent and the agent exited 0
//	N          — supervisor ran the agent and the agent exited N
//	exitUsage  — request envelope was malformed
//	exitSoftware — internal supervisor failure (I/O, panic, etc.)
//
// As of m10 the production bash shim (lib/agent.sh) calls this binary, so the
// retry envelope + quota pause logic that used to live in
// lib/agent_retry*.sh now lives behind this CLI. --no-retry is the escape
// hatch for the parity test fixtures that need to assert single-attempt
// behavior.
func newSuperviseCmd() *cobra.Command {
	var requestFile string
	var noRetry bool
	c := &cobra.Command{
		Use:   "supervise",
		Short: "Run an agent under supervision (reads agent.request.v1 JSON, prints agent.response.v1 JSON).",
		Long: "Reads an agent.request.v1 envelope on stdin (or from --request-file)\n" +
			"and prints the agent.response.v1 envelope on stdout. m10 made this\n" +
			"the production seam — lib/agent.sh shells to it; the bash supervisor\n" +
			"(lib/agent_monitor*.sh, lib/agent_retry*.sh) is gone. The retry\n" +
			"envelope + quota pause defaults match V3's TRANSIENT_RETRY_*\n" +
			"config keys; pass --no-retry to bypass and call Run directly.",
		// The agent.response.v1 envelope already encodes the failure mode in
		// its Outcome/ErrorMessage fields; cobra's "Error: ..." + usage block
		// would just duplicate that on stderr and pollute parity-test parsing.
		// Exit code is still set via errExitCode in main.go.
		SilenceErrors: true,
		SilenceUsage:  true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			req, err := readSuperviseRequest(requestFile, cmd.InOrStdin())
			if err != nil {
				// Parse / shape failures wrap proto.ErrInvalidRequest → exitUsage.
				// I/O failures (file-not-found, unreadable stdin) do not — they
				// surface as exitSoftware so bash callers can distinguish a bad
				// envelope from a transient I/O error.
				if errors.Is(err, proto.ErrInvalidRequest) {
					return errExitCode{code: exitUsage, err: err}
				}
				return errExitCode{code: exitSoftware, err: err}
			}
			// Validation also runs inside sup.Run for any future in-process
			// caller that bypasses this CLI layer; the redundancy is
			// intentional and cheap. See internal/supervisor/supervisor.go.
			if err := req.Validate(); err != nil {
				return errExitCode{code: exitUsage, err: err}
			}
			sup := supervisor.New(nil, nil)
			var res *proto.AgentResultV1
			if noRetry {
				res, err = sup.Run(context.Background(), req)
			} else {
				res, err = sup.Retry(context.Background(), req, supervisor.DefaultPolicy())
			}
			if err != nil {
				if errors.Is(err, proto.ErrInvalidRequest) {
					return errExitCode{code: exitUsage, err: err}
				}
				// Retry returns the classified upstream error alongside the
				// final result; surface the result to stdout (so the bash
				// shim can read the failure shape) rather than turning the
				// classification into a CLI-level error.
				if res == nil {
					return errExitCode{code: exitSoftware, err: err}
				}
			}
			res.EnsureProto()
			res.TrimStdoutTail()
			data, err := res.MarshalIndented()
			if err != nil {
				return errExitCode{code: exitSoftware, err: fmt.Errorf("supervise: marshal response: %w", err)}
			}
			if _, err := fmt.Fprintln(cmd.OutOrStdout(), string(data)); err != nil {
				return errExitCode{code: exitSoftware, err: err}
			}
			if res.ExitCode != 0 {
				return errExitCode{code: res.ExitCode, err: fmt.Errorf("agent exited %d", res.ExitCode)}
			}
			return nil
		},
	}
	c.Flags().StringVar(&requestFile, "request-file", "", "Path to agent.request.v1 JSON. Reads stdin when omitted.")
	c.Flags().BoolVar(&noRetry, "no-retry", false, "Bypass the retry+quota-pause envelope and call Run directly. Used by the parity tests.")
	return c
}

// readSuperviseRequest consumes the request envelope from --request-file or
// stdin. Parse / shape failures wrap proto.ErrInvalidRequest (caller maps to
// exitUsage). OS-level I/O failures return unwrapped errors so the caller
// can distinguish them and map to exitSoftware.
func readSuperviseRequest(path string, stdin io.Reader) (*proto.AgentRequestV1, error) {
	var data []byte
	var err error
	if path != "" {
		data, err = os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read --request-file: %w", err)
		}
	} else {
		data, err = io.ReadAll(stdin)
		if err != nil {
			return nil, fmt.Errorf("read stdin: %w", err)
		}
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("%w: empty request", proto.ErrInvalidRequest)
	}
	var req proto.AgentRequestV1
	if err := json.Unmarshal(data, &req); err != nil {
		return nil, fmt.Errorf("%w: parse: %v", proto.ErrInvalidRequest, err)
	}
	return &req, nil
}
