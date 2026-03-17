---
description: Execute phase-based implementation with walkthrough and review (Normal Mode)
---

## Overview

Normal Mode executes implementation **phase by phase**:
1. Execute one phase at a time
2. Generate walkthrough after completion
3. Present review → User accepts/rejects
4. Proceed to next phase after acceptance

## Step 1: Load Phase Info

Run prerequisites script to get FEATURE_DIR:
```bash
.spec-mix/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks
```
Parse `FEATURE_DIR` from JSON output.

Read `$FEATURE_DIR/tasks.md` and display:
```
Phase Progress:
├─ Phase 1: {name} - ✓ Complete
├─ Phase 2: {name} - ⏳ Current
└─ Phase 3: {name} - ○ Pending
```

## Step 2: Execute Current Phase

1. Display phase name and deliverables
2. Implement all deliverables
3. Write tests if applicable
4. Commit with descriptive messages
5. Mark phase complete in tasks.md

## Step 3: Generate Walkthrough (MANDATORY)

**You MUST write a walkthrough file** after completing each phase. This serves as **working memory** for the project - a record of what was done and why.

1. Get changed files and diffs:
   ```bash
   # List of changed files
   git diff --name-status HEAD~{N}  # N = number of commits in this phase

   # Get actual code changes
   git diff HEAD~{N} --unified=5
   ```

2. **Write** `$FEATURE_DIR/walkthrough-phase-{N}.md` with this content:

```markdown
# Walkthrough: Phase {N} - {Name}

**Generated**: {current date/time}
**Commits**: {number of commits in this phase}

## Summary
{2-3 sentences describing what was accomplished in this phase}

## Files Changed
| Status | File | Description |
|--------|------|-------------|
| M | src/component.ts | Added validation logic |
| A | src/utils/helper.ts | New utility functions |
{table of changed files from git diff}

## Detailed Changes

### {file path 1}
**Purpose**: {why this file was changed}

```diff
{actual diff for this file - use git diff HEAD~N -- path/to/file}
```

### {file path 2}
**Purpose**: {why this file was changed}

```diff
{actual diff for this file}
```

{repeat for each significant file changed}

## Key Decisions
- **Decision**: {what decision was made}
  - **Reason**: {why this approach was chosen}
  - **Alternatives considered**: {other options that were rejected}

## Working Memory Notes
> Context and notes for future reference when revisiting this code:
> - {important context about implementation choices}
> - {gotchas or things to remember}
> - {dependencies or related files to check}

## Commits
| Hash | Message |
|------|---------|
{list commits made for this phase with git log --oneline}
```

**Important**:
- This file serves as **working memory** - include enough detail that you or another developer can understand what was done and why
- Include actual diffs for significant changes
- Document decisions and their reasoning
- Add notes that would be helpful when revisiting this code later

## Step 4: Present Review

```markdown
## Phase {N} Complete - Review

📄 Walkthrough: `walkthrough-phase-{N}.md`

### Summary
{2-3 sentences}

### Files Modified
- {file list}

---
| Choice | Action |
|--------|--------|
| **ACCEPT** | Proceed to next phase |
| **REJECT** | Request changes |

Type ACCEPT or REJECT:
```

## Step 5: Handle Decision

**ACCEPT**: Mark accepted, proceed to next phase (or final completion)
**REJECT**: Get feedback, make changes, re-generate walkthrough

## Step 6: Final Completion

When all phases accepted:
```markdown
## Implementation Complete

All phases accepted. Run `/spec-mix.merge` to finalize.
```
