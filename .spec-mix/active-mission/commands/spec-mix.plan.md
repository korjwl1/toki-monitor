---
description: Generate implementation plan with technical design artifacts
---

## User Input

```text
$ARGUMENTS
```

## Setup

```bash
.spec-mix/scripts/bash/setup-plan.sh --json
```

Parse: FEATURE_SPEC, IMPL_PLAN, SPECS_DIR, BRANCH

## Execution Flow

### 1. Load Context

- Read FEATURE_SPEC (spec.md)
- Read `specs/constitution.md` if exists (for project principles)
- Load plan template from `.spec-mix/active-mission.spec-mix/templates/plan-template.md`

### 2. Fill Technical Context

In IMPL_PLAN, complete:
- Tech stack decisions
- Architecture approach
- External dependencies
- Mark unknowns as `[NEEDS CLARIFICATION]`

### 3. Phase 0: Research

Generate `research.md`:
- Resolve all `[NEEDS CLARIFICATION]`
- Document decisions with rationale

### 4. Phase 1: Design

Generate artifacts:
- `data-model.md` - entities, relationships
- `contracts/` - API specifications
- `quickstart.md` - integration guide

Update agent context: `.spec-mix/scripts/bash/update-agent-context.sh generic`

### 5. Mode-Specific Tasks

Check mode: `cat .spec-mix/config.json | grep '"mode"'`

**Normal Mode**: Generate phase-based tasks
```markdown
## Phase 1: {Name}
- Description: {what}
- Deliverables: {files}
- Acceptance: {criteria}

## Phase 2: {Name}
...
```
- Max 5 phases
- Each phase = one session

**Pro Mode**: Stop after design, report artifacts
- User runs `/spec-mix.tasks` separately

### 6. Completion

**Normal Mode**:
```
✓ Planning complete

Generated:
- Checklist: checklists/requirements.md
- Plan: plan.md
- Tasks: tasks.md ({N} phases)

Next: /spec-mix.implement
```

**Pro Mode**:
```
✓ Planning complete

Generated:
- Plan: plan.md
- Research: research.md
- Data Model: data-model.md
- Contracts: contracts/

Next: /spec-mix.tasks
```
