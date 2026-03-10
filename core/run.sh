#!/usr/bin/env bash
# =============================================================================
# claude-todo-worker — Generic daily TODO worker
#
# Picks a TODO item from the target repo, implements it in an isolated
# git worktree, and opens a PR for review.
#
# Safe to run while another session is active — uses worktree isolation.
#
# Safety guarantees:
#   - Lock file prevents concurrent runs on the same repo
#   - Never stashes anything (stashes are global — causes cross-branch confusion)
#   - Never force-removes worktrees with uncommitted/unpushed work
#   - Preserves worktree + branch on any failure for manual recovery
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve repo directory from script location
# ---------------------------------------------------------------------------
# This script lives at <repo>/.claude/daily-worker/run.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source per-repo config
CONFIG_FILE="$SCRIPT_DIR/config.sh"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Defaults (overridable via config.sh)
VENV_PATH="${VENV_PATH:-}"
BRANCH_PREFIX="${BRANCH_PREFIX:-auto}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

# Derived paths
LOG_DIR="$SCRIPT_DIR/logs"
WORKTREE_BASE="$SCRIPT_DIR/worktrees"
LOCK_FILE="$SCRIPT_DIR/.lock"
DATE=$(date +%Y-%m-%d)
RUN_ID="${DATE}-$(date +%H%M%S)"
LOG_FILE="$LOG_DIR/${RUN_ID}.log"
BRANCH_NAME="${BRANCH_PREFIX}/${DATE}"
WORKTREE_DIR="$WORKTREE_BASE/${DATE}"

# ---------------------------------------------------------------------------
# Parse optional arguments
# ---------------------------------------------------------------------------
TODO_ITEM=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --todo)
            TODO_ITEM="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--todo \"description of specific TODO item\"]"
            echo ""
            echo "Options:"
            echo "  --todo    Target a specific TODO item instead of auto-selecting"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Auto-pick by priority"
            echo "  $0 --todo \"cycle detection\"           # Work on a specific item"
            echo "  $0 --todo \"NotImplementedError in foo\" # Target a stub"
            echo ""
            echo "Repo: $REPO_DIR"
            echo "Config: $CONFIG_FILE"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1 (use --help for usage)"
            exit 1
            ;;
    esac
done

# Homebrew paths (needed since launchd doesn't source shell profiles)
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

mkdir -p "$LOG_DIR" "$WORKTREE_BASE"

# Rotate logs older than retention period
find "$LOG_DIR" -name "*.log" -mtime +${LOG_RETENTION_DAYS} -delete 2>/dev/null || true

exec > >(tee -a "$LOG_FILE") 2>&1

REPO_NAME="$(basename "$REPO_DIR")"
echo "=========================================="
echo "TODO Worker — $REPO_NAME — $RUN_ID"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Repo: $REPO_DIR"
echo "=========================================="

# ---------------------------------------------------------------------------
# Lock: prevent concurrent runs on this repo
# ---------------------------------------------------------------------------

if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "ERROR: Another worker is already running for $REPO_NAME (PID $LOCK_PID)"
        echo "If this is stale, remove: $LOCK_FILE"
        exit 1
    else
        echo "WARNING: Stale lock file found (PID $LOCK_PID no longer running). Removing."
        rm -f "$LOCK_FILE"
    fi
fi

echo $$ > "$LOCK_FILE"

cleanup_lock() {
    rm -f "$LOCK_FILE"
}
trap cleanup_lock EXIT

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

if ! command -v claude &>/dev/null; then
    echo "ERROR: claude CLI not found in PATH"
    exit 1
fi

if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI not found in PATH"
    exit 1
fi

# ---------------------------------------------------------------------------
# Create an isolated git worktree (never touches your main working directory)
# ---------------------------------------------------------------------------

cd "$REPO_DIR"

# Fetch latest default branch without modifying the working directory
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
git fetch origin "$DEFAULT_BRANCH" 2>/dev/null || echo "WARNING: Could not fetch from origin"

# ---------------------------------------------------------------------------
# Pre-processing: Audit recent commits for manually addressed TODOs
# ---------------------------------------------------------------------------
LAST_RUN_FILE="$SCRIPT_DIR/.last_run"
TODO_FILE="$REPO_DIR/TODO.md"

if [[ -f "$TODO_FILE" ]]; then
    echo ""
    echo "--- Pre-processing: auditing recent commits ---"

    SINCE_DATE=""
    if [[ -f "$LAST_RUN_FILE" ]]; then
        SINCE_DATE=$(cat "$LAST_RUN_FILE")
        echo "Last run: $SINCE_DATE"
    else
        echo "No previous run recorded — checking last 7 days"
    fi

    python3 - "$TODO_FILE" "$SINCE_DATE" "$REPO_DIR" << 'AUDIT_SCRIPT'
import re, subprocess, sys

todo_file = sys.argv[1]
since = sys.argv[2]
repo_dir = sys.argv[3]

# Get recent commit messages
cmd = ["git", "-C", repo_dir, "log", "--oneline", "--format=%s"]
if since:
    cmd.append(f"--since={since}")
else:
    cmd.extend(["--since=7 days ago"])

result = subprocess.run(cmd, capture_output=True, text=True)
commit_messages = [m for m in result.stdout.strip().split("\n") if m.strip()]

if not commit_messages:
    print("No recent commits to audit")
    sys.exit(0)

print(f"Checking {len(commit_messages)} recent commit(s) against TODO items...")

# Read TODO items (non-strikethrough list items)
content = open(todo_file).read()
lines = content.split("\n")
modified = False

for i, line in enumerate(lines):
    # Skip already struck-through items
    if "~~" in line:
        continue
    # Match list items: - some text or - **some text**
    m = re.match(r"^(\s*[-*]\s+)(.+)", line)
    if not m:
        continue
    item_text = m.group(2).strip()
    # Strip markdown formatting for comparison
    clean_text = re.sub(r"[*_`\[\]()]", "", item_text).lower()

    # Split item into significant words (>3 chars)
    words = [w for w in re.split(r"\W+", clean_text) if len(w) > 3]
    if not words:
        continue

    for msg in commit_messages:
        msg_lower = msg.lower()
        # Require at least 60% of significant words to match
        matches = sum(1 for w in words if w in msg_lower)
        if len(words) > 0 and matches / len(words) >= 0.6:
            prefix = m.group(1)
            lines[i] = f"{prefix}~~{m.group(2)}~~"
            modified = True
            print(f"  Matched: {item_text[:70]}")
            break

if modified:
    open(todo_file, "w").write("\n".join(lines))
    print("TODO.md updated with commit-matched completions")
else:
    print("No TODO items matched recent commits")
AUDIT_SCRIPT

    # ── Clean up strikethrough items ──
    echo ""
    echo "--- Pre-processing: cleaning up completed items ---"

    python3 - "$TODO_FILE" << 'CLEANUP_SCRIPT'
import re, sys

todo_file = sys.argv[1]
content = open(todo_file).read()
lines = content.split("\n")
cleaned = []
removed = 0

for line in lines:
    # Match list items (- or *) that contain ~~strikethrough~~
    if re.match(r"^\s*[-*]\s+.*~~.+~~", line):
        removed += 1
    else:
        cleaned.append(line)

# Remove consecutive blank lines left by removal
result = re.sub(r"\n{3,}", "\n\n", "\n".join(cleaned))

if removed > 0:
    open(todo_file, "w").write(result)
    print(f"Removed {removed} completed item(s) from TODO.md")
else:
    print("No completed items to clean up")
CLEANUP_SCRIPT

    # Commit cleanup if there were changes
    if ! git -C "$REPO_DIR" diff --quiet "$TODO_FILE" 2>/dev/null; then
        echo "Committing TODO.md cleanup..."
        git -C "$REPO_DIR" add "$TODO_FILE"
        git -C "$REPO_DIR" commit -m "chore: audit and clean up completed TODO items

Automated by claude-todo-worker pre-processing." 2>&1
        git -C "$REPO_DIR" push 2>&1 || echo "WARNING: Could not push cleanup commit (branch protection?)"
    fi

    # Record this run's timestamp
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$LAST_RUN_FILE"
    echo ""
fi

# If a worktree from today already exists, check if it has unsaved work
if [[ -d "$WORKTREE_DIR" ]]; then
    echo "Found existing worktree from earlier today: $WORKTREE_DIR"

    if git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null | grep -q .; then
        echo "WARNING: Existing worktree has UNCOMMITTED changes. Preserving it."
        echo "  -> Manual recovery: cd $WORKTREE_DIR"
        BRANCH_NAME="${BRANCH_PREFIX}/${RUN_ID}"
        WORKTREE_DIR="$WORKTREE_BASE/${RUN_ID}"
    else
        UNPUSHED=$(git -C "$WORKTREE_DIR" log --oneline @{u}..HEAD 2>/dev/null || echo "")
        if [[ -n "$UNPUSHED" ]]; then
            echo "WARNING: Existing worktree has UNPUSHED commits. Preserving it."
            echo "  -> Unpushed: $UNPUSHED"
            echo "  -> Manual recovery: cd $WORKTREE_DIR && git push"
            BRANCH_NAME="${BRANCH_PREFIX}/${RUN_ID}"
            WORKTREE_DIR="$WORKTREE_BASE/${RUN_ID}"
        else
            echo "Existing worktree is clean (all work pushed). Removing it."
            git worktree remove "$WORKTREE_DIR" 2>/dev/null || true
            git branch -d "$BRANCH_NAME" 2>/dev/null || true
        fi
    fi
fi

git worktree prune 2>/dev/null || true

echo "Creating worktree at: $WORKTREE_DIR"
git worktree add -b "$BRANCH_NAME" "$WORKTREE_DIR" "origin/$DEFAULT_BRANCH" 2>&1 || {
    echo "Branch $BRANCH_NAME already exists, retrying with run ID..."
    BRANCH_NAME="${BRANCH_PREFIX}/${RUN_ID}"
    WORKTREE_DIR="$WORKTREE_BASE/${RUN_ID}"
    git worktree add -b "$BRANCH_NAME" "$WORKTREE_DIR" "origin/$DEFAULT_BRANCH" 2>&1
}

echo "Working in isolated worktree: $WORKTREE_DIR"
echo "Branch: $BRANCH_NAME"

cd "$WORKTREE_DIR"

# Activate virtualenv if configured
if [[ -n "$VENV_PATH" && -f "$VENV_PATH" ]]; then
    # shellcheck disable=SC1090
    source "$VENV_PATH"
    echo "Activated virtualenv: $VENV_PATH"
elif [[ -n "$VENV_PATH" ]]; then
    echo "WARNING: virtualenv not found at $VENV_PATH"
fi

# ---------------------------------------------------------------------------
# Run Claude Code (inside the worktree)
# ---------------------------------------------------------------------------

# Use repo-specific prompt if it exists, otherwise fall back to generic
if [[ -f "$SCRIPT_DIR/prompt.md" ]]; then
    PROMPT_FILE="$SCRIPT_DIR/prompt.md"
else
    # Fall back to generic prompt bundled with claude-todo-worker
    PROMPT_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/prompt.md"
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "ERROR: No prompt file found (checked $SCRIPT_DIR/prompt.md and generic fallback)"
    exit 1
fi

FULL_PROMPT="$(cat "$PROMPT_FILE")"

if [[ -n "$TODO_ITEM" ]]; then
    echo "Targeting specific TODO: $TODO_ITEM"
    FULL_PROMPT="${FULL_PROMPT}

## TARGETED ITEM (overrides Item Selection)

The user has requested you work on this specific item:
\"${TODO_ITEM}\"

Find the matching entry in TODO.md and work on it. If no match is found,
report the issue in the log and exit cleanly."
fi

echo ""
echo "Launching Claude Code (with caffeinate to prevent sleep)..."
echo "Prompt: $PROMPT_FILE"
echo ""

caffeinate -i -- \
    claude -p "$FULL_PROMPT" \
        --dangerously-skip-permissions \
        --verbose \
        2>&1

EXIT_CODE=$?

# ---------------------------------------------------------------------------
# Safe cleanup: only remove worktree if all work is committed AND pushed
# ---------------------------------------------------------------------------

echo ""
echo "--- Post-run safety check ---"
cd "$REPO_DIR"

SAFE_TO_REMOVE=true

if git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null | grep -q .; then
    echo "⚠ Worktree has UNCOMMITTED changes — PRESERVING worktree."
    echo "  -> Recovery: cd $WORKTREE_DIR"
    SAFE_TO_REMOVE=false
fi

UNPUSHED=$(git -C "$WORKTREE_DIR" log --oneline @{u}..HEAD 2>/dev/null || echo "NO_UPSTREAM")
if [[ "$UNPUSHED" == "NO_UPSTREAM" ]]; then
    if git ls-remote --heads origin "$BRANCH_NAME" 2>/dev/null | grep -q .; then
        echo "✓ Branch exists on remote."
    else
        LOCAL_COMMITS=$(git -C "$WORKTREE_DIR" log --oneline "origin/$DEFAULT_BRANCH..HEAD" 2>/dev/null || echo "")
        if [[ -n "$LOCAL_COMMITS" ]]; then
            echo "⚠ Worktree has LOCAL-ONLY commits (never pushed) — PRESERVING worktree."
            echo "  -> Commits: $LOCAL_COMMITS"
            echo "  -> Recovery: cd $WORKTREE_DIR && git push -u origin HEAD"
            SAFE_TO_REMOVE=false
        fi
    fi
elif [[ -n "$UNPUSHED" ]]; then
    echo "⚠ Worktree has UNPUSHED commits — PRESERVING worktree."
    echo "  -> Unpushed: $UNPUSHED"
    echo "  -> Recovery: cd $WORKTREE_DIR && git push"
    SAFE_TO_REMOVE=false
fi

if [[ "$SAFE_TO_REMOVE" == true ]]; then
    echo "✓ All work committed and pushed. Removing worktree."
    git worktree remove "$WORKTREE_DIR" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
else
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  WORKTREE PRESERVED — has uncommitted or unpushed work  ║"
    echo "║  Path: $WORKTREE_DIR"
    echo "╚══════════════════════════════════════════════════════════╝"
fi

echo ""
echo "=========================================="
echo "TODO Worker finished — $REPO_NAME"
echo "Exit code: $EXIT_CODE"
echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

exit $EXIT_CODE
