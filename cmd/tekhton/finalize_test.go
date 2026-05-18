package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// runFinalizeCmd executes `tekhton finalize` with the supplied args under a
// fresh root command and returns stdout, stderr, and the resulting error.
func runFinalizeCmd(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	cmd := newFinalizeCmd()
	var stdout, stderr bytes.Buffer
	cmd.SetOut(&stdout)
	cmd.SetErr(&stderr)
	cmd.SetArgs(args)
	err := cmd.Execute()
	return stdout.String(), stderr.String(), err
}

// seedFixtureProject lays out the minimum directory shape a finalize run
// expects: .claude/milestones for the manifest, .claude/logs for stage report
// archiving, and .tekhton/ for the seeded summary files.
func seedFixtureProject(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, sub := range []string{
		filepath.Join(".claude", "milestones"),
		filepath.Join(".claude", "logs"),
		".tekhton",
	} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", sub, err)
		}
	}
	return dir
}

func TestFinalizeCmd_NoEnvelope_ExitsZero(t *testing.T) {
	dir := seedFixtureProject(t)
	_, _, err := runFinalizeCmd(t,
		"--exit-code", "0",
		"--project-dir", dir,
		"--home", dir,
		"--log-dir", filepath.Join(dir, ".claude", "logs"),
		"--timestamp", "20260518_000000",
		"--disposition", "success",
	)
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
}

func TestFinalizeCmd_LoadsRunResultEnvelope(t *testing.T) {
	dir := seedFixtureProject(t)

	// Write a RUN_RESULT.json envelope. Disposition on the envelope is the
	// source of truth — leaving --disposition off the CLI verifies the loader
	// copies it into the Input.
	envPath := filepath.Join(dir, ".tekhton", "RUN_RESULT.json")
	body, err := json.Marshal(&proto.RunResultV1{
		Proto:       proto.RunResultProtoV1,
		Disposition: proto.RunDispositionSuccess,
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(envPath, body, 0o644); err != nil {
		t.Fatalf("seed envelope: %v", err)
	}

	_, _, err = runFinalizeCmd(t,
		"--exit-code", "0",
		"--project-dir", dir,
		"--home", dir,
		"--result", envPath,
		"--log-dir", filepath.Join(dir, ".claude", "logs"),
		"--timestamp", "20260518_000000",
	)
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
}

func TestFinalizeCmd_MissingResultFile_ExitNotFound(t *testing.T) {
	dir := seedFixtureProject(t)
	_, _, err := runFinalizeCmd(t,
		"--exit-code", "0",
		"--project-dir", dir,
		"--home", dir,
		"--result", filepath.Join(dir, "does-not-exist.json"),
	)
	if err == nil {
		t.Fatal("expected error on missing result file")
	}
	var ec errExitCode
	if !errors.As(err, &ec) || ec.ExitCode() != exitNotFound {
		t.Errorf("err = %v, want errExitCode{exitNotFound}", err)
	}
}

func TestFinalizeCmd_FailureExitCode_StillRunsChain(t *testing.T) {
	dir := seedFixtureProject(t)
	// Exit code 1 with no envelope should still complete — the chain is
	// continue-on-error and the CLI must not propagate hook failures as a
	// non-zero process exit. The finalize CLI's job is to drive the chain
	// and report; it does not relay individual hook failures upward.
	_, _, err := runFinalizeCmd(t,
		"--exit-code", "1",
		"--project-dir", dir,
		"--home", dir,
		"--log-dir", filepath.Join(dir, ".claude", "logs"),
		"--timestamp", "20260518_000000",
	)
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
}

