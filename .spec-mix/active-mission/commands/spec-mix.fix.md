---
description: Create a lightweight bug fix with minimal documentation
---

## User Input

```text
$ARGUMENTS
```

Before proceeding, you **must** consider the user input (if non-empty).

## Overview

The `/spec-mix.fix` command creates a lightweight workflow for bug fixes, avoiding the full specification process. It focuses on:

1. **Minimal Documentation**: Problem → Analysis → Solution → Verification
2. **Contextual Linking**: Auto-discover related Work Packages across all features
3. **Fast Execution**: 3-step workflow (Analyze → Plan → Execute)

## Execution Flow

### Step 1: Create Fix Branch and Document

1. **Parse bug description** from `$ARGUMENTS`
   - If empty: Ask user to describe the bug

2. **Detect context**:
   - On feature branch (e.g., `001-user-auth`): Create feature-scoped fix
   - On main/master: Create hotfix

3. **Run the script** `.spec-mix/scripts/bash/create-fix.sh --json "$ARGUMENTS"`:
   ```bash
   .spec-mix/scripts/bash/create-fix.sh --json "$ARGUMENTS"
   ```

4. **Parse JSON output**:
   - `FIX_ID`: The fix identifier (e.g., FIX01, HOTFIX-01-auth)
   - `FIX_TYPE`: "fix" or "hotfix"
   - `BRANCH_NAME`: The created branch name
   - `FIX_FILE`: Path to the fix document
   - `RELATED_WPS`: Related Work Packages found
   - `PRIORITY`: Suggested priority (P0-P3)

### Step 2: Analyze Root Cause

1. **Read the fix document** at `FIX_FILE`

2. **Search for related context**:
   - Grep codebase for error messages or keywords from bug description
   - Find files related to the bug
   - Check commit history for recent changes in affected areas

3. **Fill in Root Cause Analysis section**:
   - Hypothesis: What you think is causing the issue
   - Evidence: Code references, logs, reproduction steps
   - Related Code: List specific file:line references

4. **Review related Work Packages** listed in `RELATED_WPS`:
   - Load each WP to understand original implementation
   - Note any relevant context for the fix

### Step 3: Create Fix Plan

1. **Determine fix approach**:
   - Summarize in 1-2 sentences
   - Keep it minimal - this is a fix, not a feature

2. **List changes required**:
   - Specific files to modify
   - Tests to add or update

3. **Assess risk level**:
   - Low: Isolated change, no side effects
   - Medium: Multiple files, some integration points
   - High: Core functionality, needs careful testing

4. **Confirm priority with user**:
   - Show suggested priority based on keywords
   - Allow user to override if needed

### Step 4: Execute Fix

1. **Implement the fix**:
   - Make minimal changes to resolve the bug
   - Follow existing code patterns
   - Avoid scope creep - fix only the reported issue

2. **Add/update tests**:
   - Test case that reproduces the bug (should pass after fix)
   - Regression tests as needed

3. **Commit with fix reference**:
   ```bash
   git add .
   git commit -m "[FIX_ID] Brief description of fix"
   ```

4. **Update fix document**:
   - Mark verification checkboxes as complete
   - Update status to "done" in frontmatter
   - Add activity log entry with completion timestamp

### Step 5: Create PR

After verification is complete:

1. **Push branch**:
   ```bash
   git push -u origin {BRANCH_NAME}
   ```

2. **Create Pull Request**:
   ```bash
   gh pr create --title "[FIX_ID] Brief description" --body "## Fix Summary

   **Bug**: {BUG_DESCRIPTION}
   **Priority**: {PRIORITY}
   **Fix Document**: {FIX_FILE}

   ## Changes
   - [List of changes made]

   ## Testing
   - [Tests added/verified]

   ## Related
   - Work Packages: {RELATED_WPS}
   "
   ```

3. **Report PR URL** to user

## Priority Keywords Reference

| Priority | Trigger Keywords |
|----------|------------------|
| P0 (Critical) | security, crash, data loss, production, urgent |
| P1 (High) | broken, error, fails, blocking, regression |
| P2 (Medium) | incorrect, wrong, unexpected, issue, bug |
| P3 (Low) | minor, cosmetic, typo, improvement |

## Fix Types

### Feature-scoped Fix
- **Branch**: `{FEATURE}-fix-{NUM}` (e.g., `001-user-auth-fix-01`)
- **Document**: `specs/{FEATURE}/fixes/FIX{NUM}.md`
- **Use when**: Bug is within an existing feature's scope

### Hotfix
- **Branch**: `hotfix-{NUM}-{description}` (e.g., `hotfix-01-auth-timeout`)
- **Document**: `specs/hotfix/HOTFIX-{NUM}-{description}.md`
- **Use when**: Critical bug on main that needs immediate attention

## Completion

After successful PR creation, report to user:
- Fix ID and branch name
- Fix document location
- PR URL
- Related Work Packages that were referenced
