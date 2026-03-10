#!/usr/bin/env bash
# =============================================================================
# claude-todo-worker — Uninstall from a target repo
#
# Usage:
#   ./uninstall.sh ~/path/to/repo [--remove-files]
# =============================================================================
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <repo-path> [--remove-files]"
    echo ""
    echo "Options:"
    echo "  --remove-files    Also remove .claude/daily-worker/ directory"
    echo "                    (default: keeps files, only removes launchd agent)"
    exit 0
fi

REPO_DIR="$(cd "$1" && pwd)"
REMOVE_FILES=false
[[ "${2:-}" == "--remove-files" ]] && REMOVE_FILES=true

REPO_NAME="$(basename "$REPO_DIR")"
LABEL="com.claude.todo-worker.${REPO_NAME}"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
WORKER_DIR="$REPO_DIR/.claude/daily-worker"

echo "=========================================="
echo "claude-todo-worker — Uninstalling"
echo "=========================================="
echo "Repo:  $REPO_DIR"
echo "Label: $LABEL"
echo ""

# ---------------------------------------------------------------------------
# Check for preserved worktrees with unsaved work
# ---------------------------------------------------------------------------
if [[ -d "$WORKER_DIR/worktrees" ]]; then
    ACTIVE_WORKTREES=$(find "$WORKER_DIR/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    if [[ -n "$ACTIVE_WORKTREES" ]]; then
        echo "⚠ Found active worktrees:"
        echo "$ACTIVE_WORKTREES" | while read -r wt; do
            echo "  - $wt"
            if git -C "$wt" status --porcelain 2>/dev/null | grep -q .; then
                echo "    ↳ HAS UNCOMMITTED CHANGES"
            fi
        done
        echo ""
        echo "These worktrees may contain unsaved work."
        read -rp "Continue with uninstall? [y/N] " confirm
        if [[ "$confirm" != [yY] ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Unload launchd agent
# ---------------------------------------------------------------------------
if [[ -f "$PLIST_PATH" ]]; then
    echo "Unloading launchd agent..."
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "✓ Removed: $PLIST_PATH"
else
    echo "No launchd plist found (already removed?)"
fi

# ---------------------------------------------------------------------------
# Remove pre-commit hook entry if present
# ---------------------------------------------------------------------------
PRE_COMMIT_CONFIG="$REPO_DIR/.pre-commit-config.yaml"
if [[ -f "$PRE_COMMIT_CONFIG" ]] && grep -q "update-todo-patches" "$PRE_COMMIT_CONFIG" 2>/dev/null; then
    echo "Removing update-todo-patches hook from .pre-commit-config.yaml..."
    # Remove the local repo block containing update-todo-patches
    python3 -c "
import re
path = '$PRE_COMMIT_CONFIG'
content = open(path).read()
# Remove the entire local repo block for update-todo-patches
# Match from the comment or '- repo: local' through the hook definition
pattern = r'\n?\s*#[^\n]*TODO\.md[^\n]*\n\s*- repo: local\n\s*hooks:\n\s*- id: update-todo-patches\n(?:\s+\w[^\n]*\n)*'
new_content = re.sub(pattern, '', content)
if new_content != content:
    open(path, 'w').write(new_content)
    print('Removed hook entry')
else:
    print('Could not auto-remove hook entry — please remove manually')
" 2>&1
fi

# ---------------------------------------------------------------------------
# Remove files if requested
# ---------------------------------------------------------------------------
if [[ "$REMOVE_FILES" == true ]]; then
    if [[ -d "$WORKER_DIR" ]]; then
        echo "Removing worker directory..."
        rm -rf "$WORKER_DIR"
        echo "✓ Removed: $WORKER_DIR"
    fi
else
    echo ""
    echo "Worker files preserved at: $WORKER_DIR"
    echo "  (use --remove-files to delete them)"
fi

echo ""
echo "✓ Uninstall complete for $REPO_NAME"
