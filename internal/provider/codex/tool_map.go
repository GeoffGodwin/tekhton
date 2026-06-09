package codex

// codexToolMap maps Tekhton canonical tool names to Codex's tool
// permission keys. Used by translateTools to build the -c
// tools.allowed=[...] inline config arg.
//
// The Codex CLI doesn't expose Read/Write/Edit as separate tools —
// they're all expressed through the shell tool's allowed_commands.
// The mapping below translates Tekhton semantics to Codex's coarser
// permission categories.
var codexToolMap = map[string]string{
	"Read":  "fs_read",  // Codex's filesystem read permission key
	"Write": "fs_write", // Filesystem write permission key
	"Edit":  "fs_write", // Edit = read + write; mapped to write (read is implied)
	"Bash":  "shell",    // Full shell exec
	"Glob":  "fs_read",  // Pattern matching is read-only
	"Grep":  "fs_read",  // Content search is read-only
}

// codexToolName returns the Codex permission key for a Tekhton
// canonical tool name. Returns ("", false) for unknown names so
// translateTools can route to a safe default.
func codexToolName(tekhtonName string) (string, bool) {
	v, ok := codexToolMap[tekhtonName]
	return v, ok
}
