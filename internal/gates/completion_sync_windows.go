//go:build windows

package gates

// bestEffortSync is a no-op on Windows — syscall.Sync is unavailable on
// the GOOS=windows build target. The grace window still helps narrow the
// observed transient-flake race; we just skip the explicit fsync hint.
func bestEffortSync() {}
