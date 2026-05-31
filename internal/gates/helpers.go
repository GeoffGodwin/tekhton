package gates

import "os"

// defaultEnviron is the real-environment lookup used by BashRemediator.
// Wrapped behind osEnviron so tests can stub it.
func defaultEnviron() []string { return os.Environ() }
