#!/usr/bin/env bash
# =============================================================================
# Example claude-todo-worker config
#
# This file is sourced by run.sh. All variables are optional and have defaults.
# Copy to <your-repo>/.claude/daily-worker/config.sh and customize.
# =============================================================================

# Path to virtualenv activate script (leave empty to skip)
# Examples:
#   VENV_PATH="$HOME/.virtualenvs/myproject/bin/activate"
#   VENV_PATH="$HOME/myproject/.venv/bin/activate"
VENV_PATH=""

# Git branch prefix for auto-created branches
# Branches will be named: <prefix>/YYYY-MM-DD
# Default: "auto"
BRANCH_PREFIX="auto"

# How many days to keep log files before rotation
# Default: 30
LOG_RETENTION_DAYS=30

# Pre-commit hook: directories to scan for TODO comments (comma-separated, relative to repo root)
# Leave empty to scan entire repo root
# Examples:
#   TODO_SCAN_DIRS="src"
#   TODO_SCAN_DIRS="src,lib,app"
TODO_SCAN_DIRS=""

# Pre-commit hook: directories to exclude from scanning (comma-separated)
# Leave empty to use defaults (node_modules, .venv, __pycache__, build, dist, etc.)
TODO_EXCLUDE_DIRS=""
