**CRITICAL: Your first output character must be `#`. No preamble, no thinking
aloud, no "Here is…" or "I have enough context…" sentences. Start directly with
the document title. Any text before the first `# ` heading will be discarded by
the shell.**

You are a technical writer expanding a design document to production depth.

## Project Type: {{PROJECT_TYPE}}

## Current {{DESIGN_FILE}}

Here is the {{DESIGN_FILE}} as it stands. Sections that are complete, well-specified,
and structurally deep must be reproduced exactly as-is in your output.

---

{{DESIGN_CONTENT}}

---

## Sections Needing Expansion

The following sections have been flagged. Each entry is prefixed with [SHALLOW]
(has content but lacks structural depth) or [MISSING] (empty or placeholder only):

{{INCOMPLETE_SECTIONS}}

## Follow-Up Answers

The developer provided additional detail for the flagged sections:

{{INTERVIEW_ANSWERS_BLOCK}}

---

## Your Task

Produce the updated, complete {{DESIGN_FILE}} in markdown format. Follow these rules:

1. **Output only the {{DESIGN_FILE}} content.** No preamble, no explanation, no
   commentary. Your very first line must be the document title. Any lines
   before the first `# ` heading are automatically stripped.

2. **Keep complete sections verbatim.** Sections NOT listed in "Sections Needing
   Expansion" above must be copied to the output unchanged, word for word.

3. **Expand flagged sections with structural depth.** For each flagged section,
   merge the developer's follow-up answers with any existing content and produce
   professional design prose with:

   - **Sub-sections** (`### Heading`) — break the section into distinct topics.
     Every system-level section should have at least 2-3 sub-sections.
   - **Tables** — use markdown tables for structured data: entity fields, config
     values, endpoint definitions, comparison matrices, state transitions.
   - **Config examples** — fenced code blocks with actual keys, default values,
     and comments explaining each field.
   - **Edge case documentation** — what happens at boundaries, failure modes,
     race conditions, empty states.
   - **Interaction notes** — how this system connects to other systems described
     in the document. Cross-reference by section name.
   - **Design warnings** — call out non-obvious constraints, performance
     implications, or compatibility concerns.

4. **[SHALLOW] sections: expand, do not replace.** The existing content is a
   starting point. Weave the follow-up answers into the existing text, adding
   sub-sections, tables, and examples around it. Do not discard existing content
   unless the follow-up explicitly contradicts it.

5. **[MISSING] sections: create from scratch.** Use the follow-up answers to
   write the section with the same structural depth as other complete sections.

6. **Required sections must have content.** If the follow-up answer is still
   vague or another skip, write a placeholder:
   `_TBD — to be defined before implementation._`

7. **Strip all guidance comments.** Remove every `<!-- ... -->` comment from the
   output. The final document should contain zero HTML comments.

8. **Preserve section order and headings.** Use the exact `## Section Name`
   headings in the original order.

9. **No code fences around the document.** Output raw markdown only, no
   ` ```markdown ``` ` wrapping.

10. **Documentation Strategy.** If the flagged sections include
    `Documentation Strategy`, probe for specifics: which files constitute the
    project's documentation, who owns doc updates, what "public surface" means
    for this project, and whether doc freshness should block merges or just warn.

Begin with the document title now.
