package crawler

import "errors"

// ErrRescanNotImplemented is returned by the Cobra `tekhton crawler
// rescan` subcommand until m30.2 lands the incremental rescan port.
// Defined here (not in cmd/) so callers that import the package can
// errors.Is-check it.
var ErrRescanNotImplemented = errors.New("crawler: rescan not yet implemented (m30.2)")
