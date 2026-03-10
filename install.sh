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
#   --pre-commit-hook Install pre-commit hook for auto-updating TODO.md patches
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
INSTALL_HOOK=false

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
    echo "  --pre-commit-hook  Install pre-commit hook for auto-updating TODO.md patches"
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
        --pre-commit-hook) INSTALL_HOOK=true; shift ;;
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
# Ensure TODO.md exists with proper section markers
# ---------------------------------------------------------------------------
TODO_FILE="$REPO_DIR/TODO.md"
if [[ ! -f "$TODO_FILE" ]]; then
    echo "Creating TODO.md with section markers..."
    cat > "$TODO_FILE" <<'TODO_EOF'
# TODO — Patches & Features

> **Auto-updated**: The **Patches** section is regenerated by a pre-commit hook
> that scans for `TODO` comments and not-implemented stubs in the source.
> The **Features** section is curated manually (by human or AI assistant) to track
> planned modules and capabilities.

---

## Patches


## Features

TODO_EOF
else
    # Check for missing section markers
    HAS_PATCHES=$(grep -c "^## Patches" "$TODO_FILE" 2>/dev/null || echo "0")
    HAS_FEATURES=$(grep -c "^## Features" "$TODO_FILE" 2>/dev/null || echo "0")

    if [[ "$HAS_PATCHES" -eq 0 ]] || [[ "$HAS_FEATURES" -eq 0 ]]; then
        echo "Adding missing section markers to TODO.md..."
        EXISTING_CONTENT=$(cat "$TODO_FILE")
        {
            if [[ "$HAS_PATCHES" -eq 0 ]]; then
                echo ""
                echo "## Patches"
                echo ""
            fi
            if [[ "$HAS_FEATURES" -eq 0 ]]; then
                echo ""
                echo "---"
                echo ""
                echo "## Features"
                echo ""
            fi
        } >> "$TODO_FILE"
    else
        echo "TODO.md already has required section markers"
    fi
fi

# ---------------------------------------------------------------------------
# Install pre-commit hook (optional)
# ---------------------------------------------------------------------------
if [[ "$INSTALL_HOOK" == true ]]; then
    echo "Installing pre-commit hook..."
    cp "$SCRIPT_DIR/core/update_todo_patches.py" "$WORKER_DIR/update_todo_patches.py"
    chmod +x "$WORKER_DIR/update_todo_patches.py"

    PRE_COMMIT_CONFIG="$REPO_DIR/.pre-commit-config.yaml"

    if [[ -f "$PRE_COMMIT_CONFIG" ]]; then
        # Check if hook already installed
        if grep -q "update-todo-patches" "$PRE_COMMIT_CONFIG" 2>/dev/null; then
            echo "Pre-commit hook entry already exists in .pre-commit-config.yaml"
        else
            echo "Appending hook entry to existing .pre-commit-config.yaml..."
            echo "" >> "$PRE_COMMIT_CONFIG"
            sed "s|__WORKER_DIR__|$WORKER_DIR|g" \
                "$SCRIPT_DIR/templates/pre-commit-config-snippet.yaml" >> "$PRE_COMMIT_CONFIG"
        fi
    else
        echo "Creating .pre-commit-config.yaml..."
        cat > "$PRE_COMMIT_CONFIG" <<'PRECOMMIT_HEADER'
# See https://pre-commit.com for more information
repos:
  # ── General file hygiene ───────────────────────────────────────────
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
        args: [--markdown-linebreak-ext=md]
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-added-large-files
        args: ["--maxkb=500"]

PRECOMMIT_HEADER
        sed "s|__WORKER_DIR__|$WORKER_DIR|g" \
            "$SCRIPT_DIR/templates/pre-commit-config-snippet.yaml" >> "$PRE_COMMIT_CONFIG"
    fi

    # Check if pre-commit CLI is available
    if command -v pre-commit &>/dev/null; then
        echo "Running pre-commit install..."
        cd "$REPO_DIR" && pre-commit install
        cd - >/dev/null
    else
        echo ""
        echo "WARNING: 'pre-commit' CLI not found."
        echo "  Install it and activate the hooks:"
        echo "    pip install pre-commit"
        echo "    cd $REPO_DIR && pre-commit install"
    fi
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
