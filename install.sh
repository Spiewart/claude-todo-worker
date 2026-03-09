#!/usr/bin/env bash
# =============================================================================
# claude-todo-worker — Install to a target repo
#
# Usage:
#   ./install.sh ~/path/to/repo [options]
#
# Options:
#   --venv PATH       Path to virtualenv activate script
#   --hour N          Schedule hour (0-23, default: 2)
#   --minute N        Schedule minute (0-59, default: 0)
#   --prefix NAME     Branch prefix (default: "auto")
#   --timeout N       Max run time in seconds (default: 7200)
#   --no-schedule     Install files only, skip launchd setup
#   --force           Overwrite existing prompt.md and config.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
REPO_DIR=""
VENV_PATH=""
HOUR=2
MINUTE=0
BRANCH_PREFIX="auto"
TIMEOUT=7200
SKIP_SCHEDULE=false
FORCE=false

usage() {
    echo "Usage: $0 <repo-path> [options]"
    echo ""
    echo "Arguments:"
    echo "  repo-path          Path to the git repository"
    echo ""
    echo "Options:"
    echo "  --venv PATH        Path to virtualenv activate script"
    echo "  --hour N           Schedule hour (0-23, default: 2)"
    echo "  --minute N         Schedule minute (0-59, default: 0)"
    echo "  --prefix NAME      Branch prefix (default: \"auto\")"
    echo "  --timeout N        Max run time in seconds (default: 7200)"
    echo "  --no-schedule      Install files only, skip launchd setup"
    echo "  --force            Overwrite existing prompt.md and config.sh"
    echo "  --help, -h         Show this help"
    exit 0
}

if [[ $# -eq 0 ]]; then
    usage
fi

REPO_DIR="$(cd "$1" && pwd)"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --venv)       VENV_PATH="$2"; shift 2 ;;
        --hour)       HOUR="$2"; shift 2 ;;
        --minute)     MINUTE="$2"; shift 2 ;;
        --prefix)     BRANCH_PREFIX="$2"; shift 2 ;;
        --timeout)    TIMEOUT="$2"; shift 2 ;;
        --no-schedule) SKIP_SCHEDULE=true; shift ;;
        --force)      FORCE=true; shift ;;
        --help|-h)    usage ;;
        *)            echo "Unknown option: $1"; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "ERROR: $REPO_DIR is not a git repository"
    exit 1
fi

REPO_NAME="$(basename "$REPO_DIR")"
WORKER_DIR="$REPO_DIR/.claude/daily-worker"
LABEL="com.claude.todo-worker.${REPO_NAME}"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"

echo "=========================================="
echo "claude-todo-worker — Installing"
echo "=========================================="
echo "Repo:     $REPO_DIR"
echo "Name:     $REPO_NAME"
echo "Schedule: ${HOUR}:$(printf '%02d' $MINUTE) daily"
echo "Branch:   ${BRANCH_PREFIX}/YYYY-MM-DD"
echo "Venv:     ${VENV_PATH:-none}"
echo "Label:    $LABEL"
echo ""

# ---------------------------------------------------------------------------
# Create directory structure
# ---------------------------------------------------------------------------
echo "Creating directory structure..."
mkdir -p "$WORKER_DIR/logs" "$WORKER_DIR/worktrees"

# ---------------------------------------------------------------------------
# Install run.sh
# ---------------------------------------------------------------------------
echo "Installing run.sh..."
cp "$SCRIPT_DIR/core/run.sh" "$WORKER_DIR/run.sh"
chmod +x "$WORKER_DIR/run.sh"

# ---------------------------------------------------------------------------
# Install prompt.md (only if not already customized)
# ---------------------------------------------------------------------------
if [[ -f "$WORKER_DIR/prompt.md" ]] && [[ "$FORCE" != true ]]; then
    echo "Keeping existing prompt.md (use --force to overwrite)"
else
    echo "Installing prompt.md..."
    cp "$SCRIPT_DIR/core/prompt.md" "$WORKER_DIR/prompt.md"
fi

# ---------------------------------------------------------------------------
# Generate config.sh
# ---------------------------------------------------------------------------
if [[ -f "$WORKER_DIR/config.sh" ]] && [[ "$FORCE" != true ]]; then
    echo "Keeping existing config.sh (use --force to overwrite)"
else
    echo "Generating config.sh..."
    sed -e "s|__REPO_NAME__|$REPO_NAME|g" \
        -e "s|__VENV_PATH__|$VENV_PATH|g" \
        -e "s|__BRANCH_PREFIX__|$BRANCH_PREFIX|g" \
        "$SCRIPT_DIR/templates/config.sh.tpl" > "$WORKER_DIR/config.sh"
fi

# ---------------------------------------------------------------------------
# Ensure .claude is gitignored
# ---------------------------------------------------------------------------
GITIGNORE="$REPO_DIR/.gitignore"
if [[ -f "$GITIGNORE" ]]; then
    if ! grep -q "\.claude" "$GITIGNORE" 2>/dev/null; then
        echo "Adding .claude to .gitignore..."
        echo ".claude" >> "$GITIGNORE"
    fi
else
    echo "Creating .gitignore with .claude entry..."
    echo ".claude" > "$GITIGNORE"
fi

# ---------------------------------------------------------------------------
# Generate and load launchd plist
# ---------------------------------------------------------------------------
if [[ "$SKIP_SCHEDULE" == true ]]; then
    echo "Skipping launchd setup (--no-schedule)"
else
    echo "Generating launchd plist..."

    # Unload existing agent if present
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true

    sed -e "s|__LABEL__|$LABEL|g" \
        -e "s|__REPO_DIR__|$REPO_DIR|g" \
        -e "s|__HOUR__|$HOUR|g" \
        -e "s|__MINUTE__|$MINUTE|g" \
        -e "s|__HOME__|$HOME|g" \
        -e "s|__TIMEOUT__|$TIMEOUT|g" \
        "$SCRIPT_DIR/templates/launchd.plist.tpl" > "$PLIST_PATH"

    echo "Loading launchd agent..."
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
    echo "✓ Agent loaded: $LABEL"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "✓ Installation complete!"
echo "=========================================="
echo ""
echo "Manual run:"
echo "  $WORKER_DIR/run.sh"
echo ""
echo "Target a specific TODO:"
echo "  $WORKER_DIR/run.sh --todo \"description\""
echo ""
if [[ "$SKIP_SCHEDULE" != true ]]; then
    echo "Background run:"
    echo "  launchctl kickstart gui/\$(id -u)/$LABEL"
    echo ""
    echo "Monitor:"
    echo "  tail -f $WORKER_DIR/logs/launchd-stdout.log"
    echo ""
    echo "Pause/resume:"
    echo "  launchctl bootout gui/\$(id -u) $PLIST_PATH"
    echo "  launchctl bootstrap gui/\$(id -u) $PLIST_PATH"
    echo ""
fi
echo "Customize the prompt:"
echo "  $WORKER_DIR/prompt.md"
echo ""
echo "Customize the config:"
echo "  $WORKER_DIR/config.sh"
echo ""

# Check for pmset wake schedule
if ! pmset -g sched 2>/dev/null | grep -q "wake"; then
    echo "────────────────────────────────────────"
    echo "TIP: Set up auto-wake so your Mac is awake for the scheduled run:"
    echo "  sudo pmset repeat wakeorpoweron MTWRFSU $(printf '%02d' $((HOUR > 0 ? HOUR - 1 : 23))):55:00"
    echo "────────────────────────────────────────"
fi
