---
description: Verify feature readiness and prepare for merge
---

## User Input

```text
$ARGUMENTS

```text
You **MUST** consider the user input before proceeding (if not empty).

## Outline

This command performs a final acceptance check before merging a feature. It verifies that all work is complete, quality standards are met, and the feature is ready for integration.

## Execution Flow

1. **Identify feature**:
   - Determine current feature from branch or user input
   - Locate `specs/{feature}/` directory

2. **Run comprehensive checks**:

   ### ✅ Task Completion Check

   ```bash
   # Verify all tasks are in done lane

   ls specs/{feature}/tasks/done/*.md
   ls specs/{feature}/tasks/planned/*.md
   ls specs/{feature}/tasks/doing/*.md
   ls specs/{feature}/tasks/for_review/*.md
   ```

   - **PASS**: All WP files in `done/` lane
   - **FAIL**: Tasks remaining in other lanes

   ### ✅ Artifact Completeness Check

   - [ ] `spec.md` exists and complete
   - [ ] `plan.md` exists and complete
   - [ ] `tasks.md` exists with all tasks marked `[x]`
   - [ ] `research.md` (if Phase 0 was used)
   - [ ] `data-model.md` (if applicable)

   ### ✅ Quality Gate Check

   - [ ] All acceptance criteria met (check each WP file)
   - [ ] Tests passing (run test suite if available)
   - [ ] Documentation updated
   - [ ] No [TODO] or [FIXME] markers in code
   - [ ] Code review completed

   ### ✅ Constitution Compliance (if applicable)

   - [ ] Follows project principles from `specs/constitution.md`
   - [ ] No violations of complexity gates
   - [ ] Adheres to architecture decisions

3. **Generate acceptance report**:
   ```markdown
   # Acceptance Report: {feature}

   **Date**: {timestamp}
   **Status**: READY / NOT READY

   ## Checklist Results

   ### Task Completion: ✅ / ❌

   - Total tasks: X
   - Completed: X
   - Pending: X

   ### Artifacts: ✅ / ❌

   - spec.md: ✅
   - plan.md: ✅
   - tasks.md: ✅

   ### Quality Gates: ✅ / ❌

   - All acceptance criteria met: ✅
   - Tests passing: ✅
   - Documentation complete: ✅

   ## Issues Found

   [List any blockers or concerns]

   ## Recommendation

   APPROVED FOR MERGE / NEEDS WORK
   ```

4. **Record acceptance**:
   - Create `specs/{feature}/acceptance.md` with report
   - Update `meta.json` if it exists:
     ```json
     {
       "feature": "001-user-auth",
       "accepted_at": "2025-01-12T10:30:00Z",
       "accepted_by": "claude",
       "status": "ready_for_merge"
     }
     ```

5. **Final actions**:

   **If APPROVED**:
   ```

   ✅ Feature {feature} is ready for merge!

   Next step: Run /spec-mix.merge to integrate to main branch
   ```

   **If NOT READY**:
   ```

   ❌ Feature {feature} is not ready for merge.

   Address the following issues:
   - [Issue 1]
   - [Issue 2]

   Re-run /spec-mix.accept when issues are resolved.
   ```

## Acceptance Criteria

Feature must meet ALL of the following:

1. **100% Task Completion**: All WP files in `done/` lane

2. **Artifact Completeness**: All required documents present

3. **Quality Standards**: Tests pass, documentation complete

4. **Constitution Compliance**: No principle violations

5. **Review Approval**: All tasks reviewed and approved

## Edge Cases

- **Partial completion**: Clearly identify which tasks/requirements are incomplete

- **Test failures**: Block acceptance until tests pass

- **Missing artifacts**: Guide user to create missing documents

- **Constitutional violations**: Require justification or remediation

## Output

Provide clear, actionable feedback:

```markdown

# 🎯 Acceptance Check: 001-user-authentication

## ✅ APPROVED FOR MERGE

### Summary

- All 8 tasks completed and in done lane

- All required artifacts present

- Tests passing (24/24)

- Documentation updated

- No constitution violations

### Metrics

- Completion: 100% (8/8 tasks)

- Quality score: 95%

- Test coverage: 87%

### Next Step

Ready to merge! Run:

```bash
/spec-mix.merge

```text
Or with options:

```bash
/spec-mix.merge --strategy squash    # Squash all commits

/spec-mix.merge --cleanup-worktree   # Remove worktree after merge

```text

```text
