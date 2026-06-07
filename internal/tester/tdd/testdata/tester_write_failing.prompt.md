Fixture prompt for tdd.Run tests — minimal stand-in for prompts/tester_write_failing.prompt.md.

Task: {{TASK}}

Architecture:
{{ARCHITECTURE_CONTENT}}
{{IF:REPO_MAP_CONTENT}}

Repo map:
{{REPO_MAP_CONTENT}}
{{ENDIF:REPO_MAP_CONTENT}}
{{IF:MILESTONE_BLOCK}}

Milestone:
{{MILESTONE_BLOCK}}
{{ENDIF:MILESTONE_BLOCK}}
