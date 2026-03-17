---
description: Launch the Spec Kit web dashboard
---

## User Input

```text
$ARGUMENTS

```text
You **MUST** consider the user input before proceeding (if not empty).

## Outline

This command helps you launch and manage the Spec Kit web dashboard, which provides a visual interface for monitoring features, kanban boards, and project artifacts.

## Dashboard Features

The dashboard provides:

1. **Features Overview**: View all features with their status and task counts

2. **Kanban Board**: Visualize task lanes (planned/doing/for_review/done) for each feature

3. **Artifact Viewer**: Read specifications, plans, and other documents

4. **Constitution**: View project principles and guidelines

5. **Auto-Refresh**: Real-time updates every 2 seconds

## Launching the Dashboard

### Quick Start

```bash

# Start dashboard and open in browser

spec-mix dashboard

```text

### Advanced Options

```bash

# Start on specific port

spec-mix dashboard start --port 9000

# Start without opening browser

spec-mix dashboard start

# Open browser manually

spec-mix dashboard start --open

```text

## Dashboard Commands

| Command | Description |
|---------|-------------|
| `spec-mix dashboard` | Start dashboard and open browser (default) |
| `spec-mix dashboard start` | Start dashboard server |
| `spec-mix dashboard start --port <port>` | Start on specific port |
| `spec-mix dashboard start --open` | Open in browser after start |
| `spec-mix dashboard stop` | Stop running dashboard |
| `spec-mix dashboard status` | Check if dashboard is running |

## Dashboard URL

Once started, the dashboard is available at:

```text
http://localhost:9237

```text
Or custom port if specified:

```text
http://localhost:<PORT>

```text

## What the Dashboard Shows

### Features View

- List of all features from `specs/` directory

- Features in worktrees (`.worktrees/`)

- Task counts by lane

- Available artifacts (spec, plan, tasks, etc.)

### Kanban Board

- Four lanes: Planned, Doing, For Review, Done

- Tasks (work packages) in each lane

- Task titles and IDs

- Click-through to view task details

### Artifacts

- Specification documents

- Implementation plans

- Task breakdowns

- Research notes

- Data models

- Acceptance reports

## Stopping the Dashboard

```bash

# Stop the dashboard

spec-mix dashboard stop

# Or use Ctrl+C if running in foreground

```text

## Dashboard Files

The dashboard stores state in:

```text
.spec-mix/
├── dashboard.pid    # Process ID

├── dashboard.port   # Current port

└── dashboard.token  # Shutdown authentication token

```text

## Supported Workflows

### Monitoring Feature Progress

1. Start dashboard: `spec-mix dashboard`

2. View features list

3. Click a feature to see kanban board

4. Watch tasks move through lanes in real-time

### Reviewing Artifacts

1. Open dashboard

2. Click artifact badge on feature card

3. Read rendered markdown content

4. Use back button to return

### Multi-Feature Development

1. Dashboard shows features from all worktrees

2. Each feature displays independently

3. Badge indicates which worktree (if any)

## Technical Details

- **Port Range**: Default 9237, auto-increments if busy

- **Refresh Rate**: 2 seconds for features list

- **Access**: localhost only (not exposed to network)

- **Shutdown**: Requires authentication token for security

## Integration with Workflow

The dashboard complements these commands:
- `/spec-mix.specify` - Creates features shown in dashboard

- `/spec-mix.implement` - Moves tasks through lanes

- `/spec-mix.review` - Changes task status visible in kanban

- `/spec-mix.accept` - Creates acceptance.md shown as artifact

- `/spec-mix.merge` - Completes feature lifecycle

## Troubleshooting

**Dashboard won't start:**

- Check if port is already in use: `spec-mix dashboard status`

- Try different port: `spec-mix dashboard start --port 9000`

**Features not showing:**

- Ensure `specs/` directory exists

- Check for `spec.md` in feature directories

- Refresh manually with button in UI

**Dashboard won't stop:**

- Use `spec-mix dashboard stop`

- If stuck, find process: `lsof -i :9237`

- Kill manually: `kill <PID>`

## Example Session

```bash

# Start working on a feature

cd my-project
spec-mix dashboard

# Dashboard opens showing your features

# In another terminal, work on features

/spec-mix.specify Build a new login page
/spec-mix.plan Use React and TypeScript
/spec-mix.implement

# Watch progress in dashboard as tasks move through lanes

# When done

# Dashboard auto-refreshes to show completed status

```text

## Notes

- Dashboard is read-only (no editing via web UI)

- Markdown rendering uses marked.js library

- Auto-refresh can be disabled by closing dashboard

- Multi-language support (UI adapts to system locale)
