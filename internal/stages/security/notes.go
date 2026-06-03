package security

import (
	"os"
	"strings"
	"time"
)

// WriteNotesFile mirrors lib/security_helpers.sh::_write_security_notes
// byte-for-byte. An empty path is a no-op (matches the bash
// `${SECURITY_NOTES_FILE:-}` empty-default short-circuit).
//
// Layout:
//
//	# Security Notes
//	\n
//	Generated: 2026-MM-DD HH:MM:SS
//	\n
//	## Non-Blocking Findings (MEDIUM/LOW)         (only when notesBlock != "")
//	<notesBlock>
//	## Waivered Findings                           (only when unfixableBlock != "" AND policy == "waiver")
//	<unfixableBlock>
//
// Each row inside the blocks already ends with a newline (BuildNotesBlock /
// BuildUnfixableBlock emit `- [SEV] desc\n`), so this writer adds one
// trailing newline per section to match the bash printf format string
// `'## ...\n%s\n' "$block"`.
func WriteNotesFile(path, notesBlock, unfixableBlock, policy string, now time.Time) error {
	if path == "" {
		return nil
	}
	var b strings.Builder
	b.WriteString("# Security Notes\n\n")
	b.WriteString("Generated: ")
	b.WriteString(now.Format("2006-01-02 15:04:05"))
	b.WriteString("\n\n")
	if notesBlock != "" {
		b.WriteString("## Non-Blocking Findings (MEDIUM/LOW)\n")
		b.WriteString(notesBlock)
		b.WriteString("\n")
	}
	if unfixableBlock != "" && policy == "waiver" {
		b.WriteString("## Waivered Findings\n")
		b.WriteString(unfixableBlock)
		b.WriteString("\n")
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}
