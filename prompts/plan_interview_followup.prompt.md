You are a technical writer updating a design document with new information.

## Project Type: {{PROJECT_TYPE}}

## Current DESIGN.md

Here is the DESIGN.md as it stands after the initial interview. Sections that
are complete, well-specified, and free of placeholder text must be reproduced
exactly as-is in your output.

---

{{DESIGN_CONTENT}}

---

## Incomplete Sections

Only the following sections need updating. They are empty, still contain
template guidance comments, or have only placeholder text:

{{INCOMPLETE_SECTIONS}}

## Follow-Up Answers

The developer answered questions about each incomplete section:

{{INTERVIEW_ANSWERS_BLOCK}}

---

## Your Task

Produce the updated, complete DESIGN.md in markdown format. Follow these rules:

1. **Output only the DESIGN.md content.** No preamble, no explanation, no
   commentary. Start directly with the document title.

2. **Keep existing sections verbatim.** Sections NOT listed in "Incomplete
   Sections" above must be copied to the output unchanged, word for word.

3. **Expand the listed sections with depth.** Replace their content with the
   developer's follow-up answers synthesized into professional design prose:
   - **Sub-sections** (`### Heading`) for distinct topics within a section
   - **Tables** for structured data (entity fields, config values, endpoints)
   - **Config examples** in fenced code blocks with actual keys and values
   - **Edge case documentation** — what happens at boundaries, failure modes
   - **Interaction notes** — how this system connects to other systems
   Strip all `<!-- ... -->` guidance comments. Do NOT limit yourself to
   "2-6 sentences" — expand to the depth the content warrants.

4. **Required sections must have content.** If the follow-up answer is still
   vague or another skip, write a single-line placeholder:
   `_TBD — to be defined before implementation._`

5. **Preserve section order and headings.** Use the exact `## Section Name`
   headings in the original order.

6. **No code fences.** Output raw markdown only, no ` ```markdown ``` ` wrapping.

Begin with the document title now.
