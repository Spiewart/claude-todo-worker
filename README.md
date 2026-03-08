# claude-todo-worker

Automated Claude Code agent that picks items from your `TODO.md`, implements them in an isolated git worktree, and opens PRs for review.

Deploy to any repo. Run on a schedule or on-demand.

## Quick Start

```bash
# Clone this repo
git clone https://github.com/Spiewart/claude-todo-worker.git
cd claude-todo-worker

# Install to a target repo
./install.sh ~/path/to/my-project

# Or with options
./install.sh ~/path/to/my-project \
  --venv ~/.virtualenvs/myenv/bin/activate \
  --hour 2 \
  --minute 0
```

## Requirements

- macOS (uses `launchd` for scheduling, `caffeinate` for sleep prevention)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- [GitHub CLI](https://cli.github.com/) (`gh`) — authenticated
- A git repo with a `TODO.md`

## How It Works

Every run:

1. Creates an **isolated git worktree** (your main working directory is never touched)
2. Reads `TODO.md` and picks one actionable item (highest priority first)
3. Reads `CLAUDE.md` (if present) for project-specific guidelines
4. Implements the change, runs tests, and iterates until clean
5. Commits, pushes, and opens a **PR** for your review
6. Cleans up the worktree (or preserves it if work wasn't pushed)

## Usage

### Scheduled (daily)

The installer sets up a `launchd` agent. It runs at the configured time (default: 2 AM).

```bash
# Check the schedule
launchctl print gui/$(id -u)/com.claude.todo-worker.my-project
```

### Manual (on-demand)

```bash
# Auto-pick a TODO item
~/my-project/.claude/daily-worker/run.sh

# Target a specific item
~/my-project/.claude/daily-worker/run.sh --todo "fix authentication bug"

# Background run via launchd
launchctl kickstart gui/$(id -u)/com.claude.todo-worker.my-project
```

### Monitoring

```bash
# Confirm it's running (shows PID, disappears when done)
cat ~/my-project/.claude/daily-worker/.lock

# Live tail of output
tail -f ~/my-project/.claude/daily-worker/logs/launchd-stdout.log

# Most recent log
ls -t ~/my-project/.claude/daily-worker/logs/*.log | head -1 | xargs cat
```

### Pause / Resume

```bash
# Stop the daily schedule
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.claude.todo-worker.my-project.plist

# Restart it
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude.todo-worker.my-project.plist
```

## Customization

### Per-repo config

Edit `<repo>/.claude/daily-worker/config.sh`:

```bash
# Virtual environment
VENV_PATH="$HOME/.virtualenvs/myproject/bin/activate"

# Branch prefix (branches will be: auto/YYYY-MM-DD)
BRANCH_PREFIX="auto"

# Log retention
LOG_RETENTION_DAYS=30
```

### Custom prompt

Edit `<repo>/.claude/daily-worker/prompt.md` to customize what Claude does.
The installer won't overwrite an existing `prompt.md`.

The default prompt is generic — it reads `CLAUDE.md` from your repo for
project-specific conventions, test commands, and domain rules.

## Auto-Wake (optional)

If your Mac sleeps overnight, set up auto-wake so it's awake for the scheduled run:

```bash
# Wake at 1:55 AM (5 minutes before a 2 AM schedule)
sudo pmset repeat wakeorpoweron MTWRFSU 01:55:00

# Check current wake schedule
pmset -g sched

# Remove wake schedule
sudo pmset repeat cancel
```

## Safety Guarantees

| Protection | How |
|---|---|
| **Worktree isolation** | All work happens in an isolated git worktree — your main working directory is never touched |
| **Lock file** | Prevents concurrent runs on the same repo (stale locks auto-cleared) |
| **No stashing** | Never uses `git stash` (stashes are global and cause cross-branch confusion) |
| **No force cleanup** | Never force-removes worktrees with uncommitted or unpushed work |
| **Preserves failed work** | If Claude crashes, the worktree and branch are preserved with recovery instructions |
| **Sleep prevention** | `caffeinate -i` keeps the Mac awake during the run |

### Recovering preserved worktrees

If a run fails, the worktree is preserved. The log shows recovery instructions:

```
⚠ Worktree has UNPUSHED commits — PRESERVING worktree.
  -> Recovery: cd /path/to/worktree && git push -u origin HEAD
```

List all active worktrees:

```bash
cd ~/my-project && git worktree list
```

Clean up after recovery:

```bash
git worktree remove /path/to/worktree
```

## Clamshell Note

If you close your MacBook lid and leave, it must be **plugged into power**
for `caffeinate` to keep it awake (macOS clamshell mode requirement).
Alternatively, enable "Prevent your Mac from automatically sleeping when
the display is off" in **System Settings > Battery > Options**.

## Installed Files

| What | Where |
|---|---|
| Worker script | `<repo>/.claude/daily-worker/run.sh` |
| Prompt | `<repo>/.claude/daily-worker/prompt.md` |
| Config | `<repo>/.claude/daily-worker/config.sh` |
| Logs | `<repo>/.claude/daily-worker/logs/` |
| Worktrees | `<repo>/.claude/daily-worker/worktrees/` |
| Lock file | `<repo>/.claude/daily-worker/.lock` |
| launchd plist | `~/Library/LaunchAgents/com.claude.todo-worker.<name>.plist` |

## Uninstall

```bash
# Remove launchd agent only (keep worker files for later)
./uninstall.sh ~/path/to/my-project

# Remove everything
./uninstall.sh ~/path/to/my-project --remove-files
```

## License

MIT
