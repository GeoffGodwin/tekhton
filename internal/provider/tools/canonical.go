// Package tools provides canonical Tekhton tool definitions. Each tool is
// expressed as a provider.ToolSchema that any provider translator can
// consume. Stages reference the per-stage slices (CoderTools, etc.) when
// populating Request.Tools (wired in m04).
package tools

import "github.com/geoffgodwin/tekhton/internal/provider"

// Read reads the contents of a file from the local filesystem.
var Read = provider.ToolSchema{
	Name:        "Read",
	Description: "Read the contents of a file from the local filesystem. Returns the file contents as a string.",
	Parameters: provider.ParameterSchema{
		Type:                 "object",
		AdditionalProperties: false,
		Required:             []string{"file_path"},
		Properties: map[string]provider.ParameterProperty{
			"file_path": {
				Type:        "string",
				Description: "Absolute path to the file to read.",
			},
			"offset": {
				Type:        "integer",
				Description: "Line number to start reading from (1-indexed). Optional.",
			},
			"limit": {
				Type:        "integer",
				Description: "Number of lines to read. Optional; defaults to 2000.",
			},
		},
	},
	BehaviorHints: provider.BehaviorHints{Reads: true},
}

// Write creates a new file or overwrites an existing one.
var Write = provider.ToolSchema{
	Name:        "Write",
	Description: "Write content to a file, creating it if it does not exist or overwriting if it does.",
	Parameters: provider.ParameterSchema{
		Type:                 "object",
		AdditionalProperties: false,
		Required:             []string{"file_path", "content"},
		Properties: map[string]provider.ParameterProperty{
			"file_path": {Type: "string", Description: "Absolute path to write."},
			"content":   {Type: "string", Description: "The content to write."},
		},
	},
	BehaviorHints: provider.BehaviorHints{ModifiesFiles: true},
}

// Edit performs an exact-string replacement in a file.
var Edit = provider.ToolSchema{
	Name:        "Edit",
	Description: "Perform an exact-string replacement in an existing file.",
	Parameters: provider.ParameterSchema{
		Type:                 "object",
		AdditionalProperties: false,
		Required:             []string{"file_path", "old_string", "new_string"},
		Properties: map[string]provider.ParameterProperty{
			"file_path":   {Type: "string", Description: "Absolute path to the file to edit."},
			"old_string":  {Type: "string", Description: "The exact text to replace."},
			"new_string":  {Type: "string", Description: "The replacement text."},
			"replace_all": {Type: "boolean", Description: "Replace all occurrences. Optional; defaults to false."},
		},
	},
	BehaviorHints: provider.BehaviorHints{ModifiesFiles: true},
}

// Bash executes a shell command.
var Bash = provider.ToolSchema{
	Name:        "Bash",
	Description: "Execute a shell command and return its output.",
	Parameters: provider.ParameterSchema{
		Type:                 "object",
		AdditionalProperties: false,
		Required:             []string{"command"},
		Properties: map[string]provider.ParameterProperty{
			"command":     {Type: "string", Description: "The shell command to execute."},
			"description": {Type: "string", Description: "Short description of what the command does. Optional."},
			"timeout":     {Type: "integer", Description: "Timeout in milliseconds. Optional."},
		},
	},
	BehaviorHints: provider.BehaviorHints{ExecutesShell: true, LongRunning: true},
}

// Glob finds files matching a glob pattern.
var Glob = provider.ToolSchema{
	Name:        "Glob",
	Description: "Find files matching a glob pattern. Returns matching file paths sorted by modification time.",
	Parameters: provider.ParameterSchema{
		Type:                 "object",
		AdditionalProperties: false,
		Required:             []string{"pattern"},
		Properties: map[string]provider.ParameterProperty{
			"pattern": {Type: "string", Description: "Glob pattern to match files against."},
			"path":    {Type: "string", Description: "Directory to search in. Optional; defaults to current directory."},
		},
	},
	BehaviorHints: provider.BehaviorHints{Reads: true},
}

// Grep searches file contents using a regular expression.
var Grep = provider.ToolSchema{
	Name:        "Grep",
	Description: "Search file contents using a regular expression. Returns matching file paths or content.",
	Parameters: provider.ParameterSchema{
		Type:                 "object",
		AdditionalProperties: false,
		Required:             []string{"pattern"},
		Properties: map[string]provider.ParameterProperty{
			"pattern":     {Type: "string", Description: "Regular expression pattern to search for."},
			"path":        {Type: "string", Description: "File or directory to search in. Optional."},
			"output_mode": {Type: "string", Description: "Output mode: files_with_matches, content, or count. Optional."},
			"glob":        {Type: "string", Description: "Glob pattern to filter files. Optional."},
		},
	},
	BehaviorHints: provider.BehaviorHints{Reads: true},
}

// CoderTools is the canonical tool set for the coder agent.
// Stages will reference this slice in m04 when wiring Request.Tools.
var CoderTools = []provider.ToolSchema{Read, Write, Edit, Bash, Glob, Grep}

// ReviewerTools is a read-only subset for the reviewer agent.
var ReviewerTools = []provider.ToolSchema{Read, Glob, Grep, Bash}

// TesterTools matches the coder set — testers can write tests.
var TesterTools = []provider.ToolSchema{Read, Write, Edit, Bash, Glob, Grep}

// IntakeTools is read-only — intake does not modify the codebase.
var IntakeTools = []provider.ToolSchema{Read, Glob, Grep}
