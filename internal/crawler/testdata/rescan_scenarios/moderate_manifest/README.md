# Moderate manifest scenario

Fixture for the rescan moderate-change path. The harness edits
package.json — a single manifest mutation should classify as moderate
and trigger deps + inventory + meta regen only.
