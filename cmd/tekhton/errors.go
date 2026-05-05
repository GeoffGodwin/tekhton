package main

// Exit code constants following sysexits(3) conventions.
const (
	exitNotFound = 1  // state.ErrNotFound: snapshot file missing
	exitCorrupt  = 2  // state.ErrCorrupt: snapshot file corrupt
	exitUsage    = 64 // EX_USAGE — request envelope rejected
	exitSoftware = 70 // EX_SOFTWARE — internal supervisor failure
)

// errExitCode lets RunE return a typed exit-code error so main.go can map
// state.ErrNotFound → exit 1 and state.ErrCorrupt → exit 2 without globals.
type errExitCode struct {
	code int
	err  error
}

func (e errExitCode) Error() string { return e.err.Error() }
func (e errExitCode) Unwrap() error { return e.err }
func (e errExitCode) ExitCode() int { return e.code }
