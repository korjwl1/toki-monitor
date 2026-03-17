---
description: Create or update the project constitution from interactive or provided principle inputs, ensuring all dependent templates stay in sync
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

You are creating or updating the project constitution at `specs/constitution.md`. Your job is to (a) collect/derive project principles, (b) create a comprehensive constitution, and (c) propagate any amendments across dependent artifacts.

Follow this execution flow:

1. Load or create the constitution:
   - **If `specs/constitution.md` exists**: Load it for updates.
   - **If it doesn't exist**: Use `.spec-mix/active-mission/constitution/constitution-template.md` as the starting template and copy its structure.
   **IMPORTANT**: The user might require less or more principles than the ones used in the template. If a number is specified, respect that - follow the general template structure. You will update the doc accordingly.

2. Collect/derive constitution content:
   - **Project name**: If user input supplies it, use it. Otherwise infer from repository name, package.json, pyproject.toml, or README.
   - **Principles**: If user specifies principles, use them. Otherwise adapt the template principles to fit the project domain.
   - **Governance**: Include ratification date (if unknown, use today's date), version (start at 1.0.0), and amendment procedure.
   - **Version management** (for updates): Increment version according to semantic versioning rules:
     - MAJOR: Backward incompatible governance/principle removals or redefinitions.
     - MINOR: New principle/section added or materially expanded guidance.
     - PATCH: Clarifications, wording, typo fixes, non-semantic refinements.
   - If version bump type ambiguous, propose reasoning before finalizing.

3. Draft the constitution content:
   - Update project name in the header (e.g., `# Project Constitution: My Project`)
   - For each principle: ensure succinct name, clear rules (bullets or paragraphs), and explicit rationale.
   - Add or modify principles based on user input and project context.
   - Ensure Governance section lists amendment procedure, versioning policy, and compliance review expectations.
   - Preserve markdown formatting and heading hierarchy.

4. Consistency propagation checklist (convert prior checklist into active validations):
   - Read `.spec-mix/active-mission.spec-mix/templates/plan-template.md` and ensure any "Constitution Check" or rules align with updated principles.
   - Read `.spec-mix/active-mission.spec-mix/templates/spec-template.md` for scope/requirements alignment—update if constitution adds/removes mandatory sections or constraints.
   - Read `.spec-mix/active-mission.spec-mix/templates/tasks-template.md` and ensure task categorization reflects new or removed principle-driven task types (e.g., observability, versioning, testing discipline).
   - Read each command file in `.spec-mix/active-mission.spec-mix/templates/commands/*.md` (including this one) to verify no outdated references (agent-specific names like CLAUDE only) remain when generic guidance is required.
   - Read any runtime guidance docs (e.g., `README.md`, `docs/quickstart.md`, or agent-specific guidance files if present). Update references to principles changed.

5. Produce a Sync Impact Report (prepend as an HTML comment at top of the constitution file after update):
   - Version change: old → new
   - List of modified principles (old title → new title if renamed)
   - Added sections
   - Removed sections
   - Templates requiring updates (✅ updated / ⚠ pending) with file paths
   - Follow-up TODOs if any placeholders intentionally deferred.

6. Validation before final output:
   - No remaining unexplained bracket tokens.
   - Version line matches report.
   - Dates ISO format YYYY-MM-DD.
   - Principles are declarative, testable, and free of vague language ("should" → replace with MUST/SHOULD rationale where appropriate).

7. Write the completed constitution back to `specs/constitution.md` (overwrite).

8. Output a final summary to the user with:
   - New version and bump rationale.
   - Any files flagged for manual follow-up.
   - Suggested commit message (e.g., `docs: amend constitution to vX.Y.Z (principle additions + governance update)`).

Formatting & Style Requirements:

- Use Markdown headings exactly as in the template (do not demote/promote levels).

- Wrap long rationale lines to keep readability (<100 chars ideally) but do not hard enforce with awkward breaks.

- Keep a single blank line between sections.

- Avoid trailing whitespace.

If the user supplies partial updates (e.g., only one principle revision), still perform validation and version decision steps.

If critical info missing (e.g., ratification date truly unknown), insert `TODO(<FIELD_NAME>): explanation` and include in the Sync Impact Report under deferred items.

Do not create a new template; always operate on the existing `specs/constitution.md` file.
