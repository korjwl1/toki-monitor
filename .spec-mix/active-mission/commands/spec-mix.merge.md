---
description: Merge feature branch to main and cleanup
---

## User Input

```text
$ARGUMENTS

```text
You **MUST** consider the user input before proceeding (if not empty).

## Outline

This command integrates a completed feature into the main branch, with options for merge strategy and cleanup.

## Prerequisites

Before running this command:

1. ✅ Feature must be accepted (run `/spec-mix.accept` first)

2. ✅ All tasks in `done/` lane

3. ✅ All tests passing

4. ✅ Working directory clean (no uncommitted changes)

## Merge Strategies

### Standard Merge (default)

```bash
/spec-mix.merge

```text
Creates a merge commit preserving full feature history.

### Squash Merge

```bash
/spec-mix.merge --strategy squash

```text
Combines all feature commits into a single commit.

### Fast-Forward Merge

```bash
/spec-mix.merge --strategy ff-only

```text
Only merge if can fast-forward (linear history).

## Options

| Option | Description |
|--------|-------------|
| `--strategy <type>` | Merge strategy: `merge`, `squash`, `ff-only` (default: `merge`) |
| `--push` | Automatically push to remote after merge |
| `--cleanup-worktree` | Remove worktree directory after successful merge |
| `--keep-branch` | Keep feature branch after merge (default: delete) |
| `--dry-run` | Preview merge without executing |
| `--no-verify` | Skip pre-merge verification |

## Execution Flow

1. **Pre-merge verification** (unless `--no-verify`):
   ```bash
   # Check acceptance status

   if [[ -f "specs/{feature}/acceptance.md" ]]; then
       # Verify status is APPROVED

   else
       echo "Error: Feature not accepted. Run /spec-mix.accept first"
       exit 1
   fi

   # Check for uncommitted changes

   if ! git diff-index --quiet HEAD --; then
       echo "Error: Working directory has uncommitted changes"
       exit 1
   fi
   ```

2. **Prepare for merge**:
   ```bash
   # Stash any changes (just in case)

   git stash save "Pre-merge stash"

   # Switch to main branch

   git checkout main

   # Pull latest changes

   git pull origin main
   ```

3. **Execute merge**:

   **Standard merge**:
   ```bash
   git merge {feature-branch} --no-ff -m "Merge feature {feature}"
   ```

   **Squash merge**:
   ```bash
   git merge {feature-branch} --squash
   git commit -m "feat: {feature-description}

   $(cat specs/{feature}/spec.md | head -20)

   Closes #{feature-number}"
   ```

   **Fast-forward**:
   ```bash
   git merge {feature-branch} --ff-only
   ```

4. **Post-merge actions**:

   a. **Push to remote** (if `--push`):
      ```bash
      git push origin main
      ```

   b. **Cleanup worktree** (if `--cleanup-worktree`):
      ```bash
      .spec-mix.spec-mix/scripts/bash/setup-worktree.sh --feature {feature} --cleanup
      ```

   c. **Delete feature branch** (unless `--keep-branch`):
      ```bash
      git branch -d {feature-branch}
      # Also delete remote branch if exists

      git push origin --delete {feature-branch} 2>/dev/null || true
      ```

5. **Archive feature documentation** (optional):
   ```bash
   # Move specs to archive

   mkdir -p archive/
   mv specs/{feature}/ archive/{feature}/
   git add archive/{feature}/
   git commit -m "chore: archive {feature} documentation"
   ```

6. **Report summary**:
   ```markdown
   ✅ Feature merged successfully!

   **Feature**: {feature}
   **Strategy**: {merge-strategy}
   **Commits**: {commit-count}
   **Branch**: main

   ### Changes

   - Files changed: {file-count}
   - Insertions: {additions}
   - Deletions: {deletions}

   ### Next Steps

   - Feature branch deleted: {feature-branch}
   - Worktree cleaned up: .worktrees/{feature}
   - Documentation archived: archive/{feature}/

   Ready to start next feature! Run:
   /spec-mix.specify "Next feature description"
   ```

## Conflict Resolution

If merge conflicts occur:

1. **Show conflict files**:
   ```bash
   git status
   ```

2. **Guide user to resolve**:
   ```markdown
   ⚠️ Merge conflicts detected in:
   - {file1}
   - {file2}

   Please resolve conflicts manually:
   1. Open conflicted files
   2. Edit to resolve conflicts
   3. Stage resolved files: git add {file}
   4. Complete merge: git commit

   Or abort merge: git merge --abort
   ```

3. **Wait for resolution**: Command pauses until conflicts resolved

## Rollback

If merge fails or user wants to undo:

```bash

# Abort ongoing merge

git merge --abort

# Or reset after completed merge (DANGEROUS)

git reset --hard HEAD~1

# Restore worktree if needed

git worktree add .worktrees/{feature} {feature-branch}

```text

## Dry Run Output

With `--dry-run`:

```markdown
🔍 Merge Preview: {feature}

**Strategy**: {merge-strategy}
**Current branch**: main
**Target branch**: {feature-branch}

### Changes to be merged:

- Commits: {commit-count}

- Files changed: {file-count}

- Tests status: ✅ Passing

### Actions that would be performed:

1. Switch to main branch

2. Pull latest changes

3. Merge {feature-branch} using {strategy}

4. [x] Push to remote

5. [x] Cleanup worktree

6. [x] Delete feature branch

⚠️ This is a dry run. No changes made.
To execute, run without --dry-run flag.

```text

## Examples

### Simple merge

```bash
/spec-mix.merge

```text

### Squash and push

```bash
/spec-mix.merge --strategy squash --push

```text

### Full cleanup

```bash
/spec-mix.merge --push --cleanup-worktree

```text

### Preview only

```bash
/spec-mix.merge --dry-run

```text

## Safety Features

- ✅ Requires acceptance before merge

- ✅ Checks for uncommitted changes

- ✅ Pulls latest main before merge

- ✅ Creates backup stash automatically

- ✅ Provides rollback instructions if issues occur
