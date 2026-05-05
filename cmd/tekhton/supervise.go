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

// Sysexits-style codes for failures internal to `tekhton supervise` itself
// (envelope invalid, internal panic, I/O on the request channel). Distinct
// from agent-side exit codes so bash callers can distinguish "the supervisor
// could not run" from "the agent ran and exited with N".
const (
	exitUsage    = 64 // EX_USAGE — request envelope rejected
	exitSoftware = 70 // EX_SOFTWARE — internal supervisor failure
)

// newSuperviseCmd wires `tekhton supervise`. The subcommand reads an
// agent.request.v1 JSON envelope (from --request-file or stdin), hands it
// to internal/supervisor.Run, and prints an agent.response.v1 JSON envelope
// on stdout. Exit code semantics:
//
//	0          — supervisor ran the agent and the agent exited 0
//	N          — supervisor ran the agent and the agent exited N
//	exitUsage  — request envelope was malformed
//	exitSoftware — internal supervisor failure (I/O, panic, etc.)
//
// In the m05 stub, Run never returns an agent-side failure — every valid
// request emits a success response. m06 fills in the real subprocess path.
func newSuperviseCmd() *cobra.Command {
	var requestFile string
	c := &cobra.Command{
		Use:   "supervise",
		Short: "Run an agent under supervision (reads agent.request.v1 JSON, prints agent.response.v1 JSON).",
		Long: "Reads an agent.request.v1 envelope on stdin (or from --request-file)\n" +
			"and prints the agent.response.v1 envelope on stdout. The supervisor\n" +
			"is currently a Phase 2 wedge — m05 ships the contract and the stub\n" +
			"path; the real subprocess invocation lands in m06.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			req, err := readSuperviseRequest(requestFile, cmd.InOrStdin())
			if err != nil {
				return errExitCode{code: exitUsage, err: err}
			}
			if err := req.Validate(); err != nil {
				return errExitCode{code: exitUsage, err: err}
			}
			sup := supervisor.New(nil, nil)
			res, err := sup.Run(context.Background(), req)
			if err != nil {
				if errors.Is(err, proto.ErrInvalidRequest) {
					return errExitCode{code: exitUsage, err: err}
				}
				return errExitCode{code: exitSoftware, err: err}
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
	return c
}

// readSuperviseRequest consumes the request envelope from --request-file or
// stdin. The error path returns a wrapped proto.ErrInvalidRequest so the
// caller maps to exitUsage uniformly.
func readSuperviseRequest(path string, stdin io.Reader) (*proto.AgentRequestV1, error) {
	var data []byte
	var err error
	if path != "" {
		data, err = os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("%w: read --request-file: %v", proto.ErrInvalidRequest, err)
		}
	} else {
		data, err = io.ReadAll(stdin)
		if err != nil {
			return nil, fmt.Errorf("%w: read stdin: %v", proto.ErrInvalidRequest, err)
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
