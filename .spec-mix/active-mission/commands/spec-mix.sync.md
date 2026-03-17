---
description: Sync context by reading all project artifacts for agent handoff
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Purpose

This command helps you quickly understand the current state of a project by reading all existing artifacts. Use this when:

- Switching from another AI agent that was working on this project
- Starting a new session after a break
- Onboarding to an existing project
- Need to understand what has been done and what's next

## Execution Flow

### 1. Identify Project Context

First, gather basic project information:

```bash
# Check project config
cat .spec-mix/config.json
```

Note the following:
- Current mode (normal/pro)
- Language setting
- Active mission
- Primary AI agent

### 2. Find Active Feature

Determine the current working feature:

```bash
# Get current branch
git branch --show-current

# List all feature specs
ls specs/
```

If on a feature branch (e.g., `003-user-auth`), that's the active feature.
If on main, look for the most recently modified spec directory.

### 3. Read Core Artifacts

For the active feature, read these files in order:

#### a. Specification (What)
```bash
cat specs/{feature}/spec.md
```
- Understand the feature requirements
- Note user stories and acceptance criteria
- Check the status field

#### b. Plan (How)
```bash
cat specs/{feature}/plan.md
```
- Understand technical approach
- Note architecture decisions
- Review implementation phases

#### c. Tasks (Progress)
```bash
cat specs/{feature}/tasks.md
```
- Check which tasks are completed `[x]`
- Which are in progress
- Which are pending

#### d. Task Lanes (Detailed Status)
```bash
ls specs/{feature}/tasks/planned/
ls specs/{feature}/tasks/doing/
ls specs/{feature}/tasks/for_review/
ls specs/{feature}/tasks/done/
```
- Count tasks in each lane
- Note any blocked tasks

### 4. Read Recent Walkthroughs

Walkthroughs contain valuable context about completed work:

```bash
ls -lt specs/{feature}/walkthroughs/
```

Read the most recent walkthrough files to understand:
- What was implemented
- Key decisions made
- Any issues encountered

### 5. Check Project Notes

```bash
cat .spec-mix/notes.md 2>/dev/null || echo "No notes found"
```

Notes may contain:
- Important reminders from previous sessions
- Warnings or gotchas
- Handoff messages from other agents

### 6. Check Constitution

```bash
cat specs/constitution.md 2>/dev/null
```

Understand project principles and guidelines.

## Output: Context Summary

After reading all artifacts, present a summary:

```markdown
# 🔄 Project Sync Complete

## Project Overview
- **Project**: {project-name}
- **Mode**: {normal/pro}
- **Language**: {en/ko}
- **Mission**: {software-dev/research}

## Active Feature: {feature-number}-{feature-name}

### Current Status
- **Spec**: ✅ Complete
- **Plan**: ✅ Complete
- **Tasks**: 🔄 In Progress (6/10 complete)

### Task Progress
| Lane | Count |
|------|-------|
| ✅ Done | 4 |
| 🔍 For Review | 2 |
| 🔨 Doing | 1 |
| 📋 Planned | 3 |

### Recent Activity
- Phase 2 completed (see `phase-2-walkthrough.md`)
- Currently working on: WP05 - API Integration
- Last updated: {timestamp}

### Notes from Previous Session
{any notes or handoff messages}

## Suggested Next Steps
1. Continue with WP05 (API Integration) in `doing/`
2. Review completed tasks in `for_review/`
3. {other suggestions based on context}

## Quick Commands
- `/spec-mix.implement` - Continue implementation
- `/spec-mix.review` - Review completed tasks
- `spec-mix note "message"` - Add a note for next session
```

## Best Practices

1. **Always sync first** when switching agents or starting a new session
2. **Read walkthroughs** - they contain the most recent context
3. **Check notes** - previous agents may have left important messages
4. **Verify understanding** - ask user to confirm if anything is unclear

## Related Commands

- `/spec-mix.implement` - Continue implementation after sync
- `/spec-mix.review` - Review completed work
- `spec-mix note` - Add/read notes for handoff
