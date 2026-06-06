//go:build !windows

package gates

import "syscall"

// bestEffortSync flushes file-system write buffers. Used by the m45
// completion-gate grace window to narrow the file-system-flush race that
// caused observed false halts after large coder refactors. Best-effort:
// the gate proceeds regardless of return value.
func bestEffortSync() {
	syscall.Sync()
}
