---
description: Migrate untracked commits to spec-driven workflow by generating retrospective specifications.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

This command helps migrate existing commits that don't have Work Package IDs into the spec-driven workflow. It analyzes what was actually implemented and generates retrospective specifications.

**Input**: Commit SHA (one or more required) - the commits to migrate

**Formats**:
- Single commit: `abc1234`
- Multiple commits: `abc1234 def5678 ghi9012` (space-separated)
- Commit range: `abc1234..def5678` (range notation)

Given the commit SHA(s), do this:

1. **Parse Input and Validate Commit SHAs**:

   a. Detect input format:
      - Range (contains `..`): Extract commit list with `git rev-list {START}..{END}`
      - Multiple SHAs (space-separated): Validate each
      - Single SHA: Validate directly

   b. Validate each commit:
      ```bash
      git rev-parse --verify {COMMIT_SHA}
      ```
      - If invalid: ERROR "Invalid commit SHA: {COMMIT_SHA}"
      - If all valid: Proceed to analysis

   c. Sort commits by date:
      ```bash
      git rev-list --no-walk --date-order {COMMIT_SHA1} {COMMIT_SHA2} ...
      ```

2. **Analyze Commits** (perform for each commit, merge results for multiple):

   a. Get commit metadata:
      ```bash
      git show --format="%H|%s|%cd|%an|%ae" --date=iso-strict --no-patch {COMMIT_SHA}
      ```

   b. Get commit diff and changed files:
      ```bash
      git show {COMMIT_SHA} --stat
      git show {COMMIT_SHA}
      ```

   c. Extract implementation details:
      - What files were changed
      - What functionality was added/modified/removed
      - What patterns or technologies were used
      - What problem was being solved

3. **Generate Feature Name**:
   - Analyze the commit message and code changes
   - Extract the core feature or fix being implemented
   - Create a concise short name (2-4 words) following these guidelines:
     - Use action-noun format: "add-user-auth", "fix-payment-bug"
     - Preserve technical terms and acronyms
     - Examples:
       - "feat: WP04.3 JSON Schema validator" → "json-schema-validator"
       - "fix: dashboard performance issue" → "fix-dashboard-performance"
       - "Add OAuth2 integration" → "oauth2-integration"

4. **Check for existing branches** (same as `/spec-mix.specify`):

   a. Fetch all remote branches:
      ```bash
      git fetch --all --prune
      ```

   b. Find the highest feature number for this short-name:
      - Remote branches: `git ls-remote --heads origin | grep -E 'refs/heads/[0-9]+-<short-name>$'`
      - Local branches: `git branch | grep -E '^[* ]*[0-9]+-<short-name>$'`
      - Specs directories: Check for `specs/[0-9]+-<short-name>`

   c. Determine next number (N+1) and run script:
      ```bash
      .spec-mix/scripts/bash/create-new-feature.sh --json "$ARGUMENTS" --json --number {N+1} --short-name "{short-name}" "Migrated from commit {SHORT_SHA}"
      ```

5. **Load Templates**:
   - Load `.spec-mix/active-mission.spec-mix/templates/spec-template.md`
   - Load `.spec-mix/active-mission.spec-mix/templates/plan-template.md`
   - Load `.spec-mix/active-mission.spec-mix/templates/tasks-template.md`

6. **Load Project Constitution** (if exists):
   - Read `specs/constitution.md` to understand project principles
   - Ensure retrospective spec aligns with project governance

7. **Generate Retrospective Specification**:

   Based on the actual implementation found in the commit:

   a. **Feature Overview**:
      - Derive the feature purpose from what was actually implemented
      - Infer user needs from the solution provided
      - Document the problem this commit solved

   b. **Functional Requirements**:
      - List what the code actually does (reverse-engineer from implementation)
      - Convert technical changes into user-facing requirements
      - Example: "Added JWT middleware" → "Users can authenticate securely"

   c. **User Scenarios & Testing**:
      - Infer user flows from the implementation
      - Derive test cases from what was actually built

   d. **Success Criteria**:
      - Define measurable outcomes based on what was delivered
      - Keep technology-agnostic where possible

   e. **Key Entities** (if applicable):
      - Document data models or entities introduced in the commit

   f. **Assumptions**:
      - Document what you inferred from the code
      - Note any ambiguities in reverse-engineering the requirements

   **Important**: This is a retrospective spec, so:
   - Write it as if you're documenting requirements that led to this implementation
   - Keep it technology-agnostic where reasonable (describe WHAT, not HOW)
   - Mark sections with `[INFERRED FROM IMPLEMENTATION]` where you're reverse-engineering
   - Don't copy code or implementation details into the spec

8. **Generate Retrospective Plan**:

   Based on how the feature was actually implemented:

   a. **Technical Context**:
      - List technologies and frameworks actually used in the commit
      - Document architectural patterns observed in the code

   b. **Implementation Approach**:
      - Describe the solution that was actually built
      - Document key design decisions evident in the code

   c. **Implementation Phases**:
      - Break down what was done into logical phases
      - Map code changes to implementation steps

   d. **Testing Strategy**:
      - Infer testing approach from test files (if any)
      - Suggest testing strategy based on what was built

   **Important**: This is a retrospective plan, so:
   - Document what was actually done, not what should have been done
   - Mark sections with `[COMPLETED]` to indicate this is post-implementation
   - Include actual file paths and components from the commit

9. **Generate Retrospective Tasks**:

   Create task breakdown based on what was actually implemented:

   a. Analyze commit changes and group into logical tasks

   b. For each task, create a Work Package file:
      - Use template structure from `work-package-template.md`
      - Mark status as `done` (since work is already completed)
      - Include actual code changes in description
      - Reference the commit SHA

   c. Place all tasks in `tasks/done/` lane (since they're already completed)

   d. Example task structure:
      ```markdown
      # WP01: [Task Name]

      **Status**: done
      **Migrated from**: {COMMIT_SHA}
      **Completed**: {COMMIT_DATE}

      ## Description
      [What was actually implemented, derived from diff]

      ## Acceptance Criteria
      - [x] [Criterion based on actual changes]

      ## Implementation Notes
      Files changed:
      - path/to/file1.js (+50, -10)
      - path/to/file2.css (+20, -5)

      ## Activity Log
      - {COMMIT_DATE}: Migrated from commit {COMMIT_SHA} by {AUTHOR}
      ```

10. **Write Files**:

    a. Write spec to `SPEC_FILE` (from script output)

    b. Write plan to `FEATURE_DIR/plan.md`

    c. Write tasks to `FEATURE_DIR/tasks/done/WP##.md`

    d. Create migration metadata (JSON format):
       ```bash
       cat > FEATURE_DIR/.migration-info << EOF
       {
         "migrated_commits": [
           "{COMMIT_SHA_1}",
           "{COMMIT_SHA_2}",
           ...
         ],
         "migrated_at": "{TIMESTAMP}",
         "commit_count": {N}
       }
       EOF
       ```

       **Important**: This file is used by the dashboard to filter out commits from untracked list.

11. **Present Results**:

    Present a summary to the user:

    ```markdown
    ## Migration Complete

    Successfully migrated commit `{SHORT_SHA}` to spec-driven workflow.

    **Original Commit**:
    - SHA: {COMMIT_SHA}
    - Message: {COMMIT_MESSAGE}
    - Author: {AUTHOR}
    - Date: {COMMIT_DATE}

    **New Feature**:
    - Branch: {BRANCH_NAME}
    - Spec: {SPEC_FILE}
    - Plan: {PLAN_FILE}
    - Tasks: {TASK_COUNT} tasks in `tasks/done/`

    **What was created**:
    - Retrospective specification (reverse-engineered from implementation)
    - Retrospective plan (documenting what was actually built)
    - Work package tasks (marked as done, includes actual changes)

    **Next Steps**:
    1. Review the generated spec/plan/tasks for accuracy
    2. Update any [INFERRED FROM IMPLEMENTATION] sections if needed
    3. Consider creating a new commit to link this feature:
       ```bash
       git commit --allow-empty -m "docs: Link commit {SHORT_SHA} to feature {BRANCH_NAME}"
       ```

    **Note**: The original commit remains in git history unchanged. This migration creates documentation for tracking purposes.
    ```

12. **Optional: Suggest Cherry-Pick** (if on main branch):

    If the original commit is on the main branch and the user wants to organize history:

    ```markdown
    ## Optional: Reorganize Git History

    To move this commit to the feature branch:

    ```bash
    # Cherry-pick the commit to the feature branch
    git checkout {BRANCH_NAME}
    git cherry-pick {COMMIT_SHA}

    # Update commit message to include WP ID
    git commit --amend -m "{COMMIT_MESSAGE} [WP01]"
    ```

    **Warning**: Only do this if:
    - The commit hasn't been pushed to remote yet
    - You're comfortable rewriting git history
    - The commit is isolated (no dependent commits)
    ```

## General Guidelines

### Reverse-Engineering from Code

When generating retrospective specs from commits:

1. **Focus on User Value**: Don't just describe code changes, infer the user need
   - Bad: "Added a JWT middleware function"
   - Good: "Users need secure authentication to access protected resources"

2. **Abstract Implementation**: Convert technical details to requirements
   - Code shows: Database schema changes
   - Spec shows: "System must persist user preferences"

3. **Infer Intent**: Use commit message, code comments, and patterns to understand purpose
   - Look for TODOs, FIXMEs, or comments explaining "why"
   - Analyze test cases to understand expected behavior

4. **Mark Uncertainty**: Use `[INFERRED FROM IMPLEMENTATION]` when reverse-engineering
   - "This appears to solve [problem] [INFERRED FROM IMPLEMENTATION]"
   - Be honest about assumptions

### Quality Validation

After generating retrospective docs:

1. **Spec should be technology-agnostic** (even though you saw the code)
2. **Plan documents actual technologies used**
3. **Tasks reference actual files and changes**
4. **All docs marked as retrospective/completed**

### Common Migration Scenarios

**Scenario 1: Feature Addition**
- Commit adds new functionality
- Generate spec describing the feature
- Plan documents how it was built
- Tasks cover implementation steps

**Scenario 2: Bug Fix**
- Commit fixes a bug
- Generate spec as "Bug: [description]"
- Plan documents the fix approach
- Single task for the fix

**Scenario 3: Refactoring**
- Commit improves code structure
- Generate spec as "Technical Improvement: [goal]"
- Plan documents refactoring approach
- Tasks cover refactoring steps

**Scenario 4: Multiple Features**
- Commit contains multiple unrelated changes
- Suggest splitting into multiple features:
  ```
  Unable to migrate: Commit contains multiple unrelated changes.
  Please create separate features for:
  1. [Feature 1 based on file group A]
  2. [Feature 2 based on file group B]

  Consider using git tools to split the commit first.
  ```
