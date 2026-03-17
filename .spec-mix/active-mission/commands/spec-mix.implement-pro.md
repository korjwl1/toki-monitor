---
description: Execute implementation with Work Package lane workflow (Pro Mode)
---

## User Input

```text
$ARGUMENTS
```

## Lane Workflow (MANDATORY)

```
planned → doing → for_review → done
```

**Rules**:
- Task MUST be in `doing` before coding
- Commits MUST include `[WP##]`
- Completed tasks MUST move to `for_review`

## Execution Flow

### 1. Run Prerequisites Script

```bash
.spec-mix/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks
```
Parse FEATURE_DIR from output.

### 2. Check Lane Status

```bash
ls $FEATURE_DIR/tasks/{planned,doing,for_review,done}/*.md 2>/dev/null | wc -l
```

Display:
```
Lane Status:
├─ planned:    X tasks
├─ doing:      X tasks
├─ for_review: X tasks
└─ done:       X tasks
```

### 3. Select Task

- If task in `doing`: Continue or select new
- If no task in `doing`: Select from `planned`

Move task:
```bash
bash .spec-mix.spec-mix/scripts/bash/move-task.sh WP## planned doing $FEATURE_DIR
```

### 4. Load Context

Read (in order):
1. `{SPEC_DIR}/tasks.md` - task list
2. `{SPEC_DIR}/plan.md` - architecture
3. `specs/constitution.md` - project principles (if exists)
4. `{SPEC_DIR}/data-model.md` (if exists)

### 5. Implement

**Before coding**: Verify task in `doing`

Execute by phase:
- Setup → Tests → Core → Integration → Polish
- Respect dependencies
- Follow TDD when applicable

### 6. Commit

Format:
```bash
git commit -m "[WP##] Brief description

- Change 1
- Change 2"
```

### 7. Complete Task

Move to review:
```bash
bash .spec-mix.spec-mix/scripts/bash/move-task.sh WP## doing for_review $FEATURE_DIR
```

### 8. Generate Walkthrough (MANDATORY - DO NOT SKIP)

⚠️ **DO NOT SKIP THIS STEP!** The walkthrough file is required for the review process.

1. Get changed files:
   ```bash
   git diff --name-status HEAD~1
   ```

2. **Write** `$FEATURE_DIR/walkthrough.md` with this content:

```markdown
# Implementation Walkthrough

**Generated**: {current date/time}
**Task**: WP## - {task title}

## Summary
{2-3 sentences describing what was implemented}

## Files Modified
| Status | File |
|--------|------|
{table of changed files from git diff}

## Key Changes
- **{file path}**: {what changed and why}

## Commits
{list commits made for this task with [WP##] tag}

## Next Steps
1. Run `/spec-mix.review` to review this implementation
2. After approval, run `/spec-mix.accept`
3. Finally, run `/spec-mix.merge` to merge to main
```

⚠️ **Important**: This file is required for the review process and dashboard visibility. Do not skip this step.

## Next Steps

```
✓ Implementation complete for WP##

Next:
1. /spec-mix.review - Review completed work
2. /spec-mix.accept - Acceptance check
3. /spec-mix.merge - Merge to main
```
