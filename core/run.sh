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

    # Phase 1: Candidate pre-filter — keyword matching to identify potential matches
    CANDIDATES_FILE="$SCRIPT_DIR/.audit_candidates.json"

    python3 - "$TODO_FILE" "$SINCE_DATE" "$REPO_DIR" "$CANDIDATES_FILE" << 'CANDIDATE_SCRIPT'
import json, re, subprocess, sys

todo_file = sys.argv[1]
since = sys.argv[2]
repo_dir = sys.argv[3]
candidates_file = sys.argv[4]

# Get recent commits with short hash + subject
cmd = ["git", "-C", repo_dir, "log", "--format=%h %s", "--no-merges"]
if since:
    cmd.append(f"--since={since}")
else:
    cmd.extend(["--since=7 days ago"])

result = subprocess.run(cmd, capture_output=True, text=True)
raw_lines = [l for l in result.stdout.strip().split("\n") if l.strip()]

if not raw_lines:
    print("No recent commits to audit")
    json.dump({"candidates": []}, open(candidates_file, "w"))
    sys.exit(0)

# Parse hash + message
commits = []
for line in raw_lines:
    parts = line.split(" ", 1)
    if len(parts) == 2:
        commits.append({"hash": parts[0], "message": parts[1]})

print(f"Checking {len(commits)} recent commit(s) against TODO items...")

# Read TODO items (non-strikethrough list items)
content = open(todo_file).read()
lines = content.split("\n")
candidates = []

MATCH_THRESHOLD = 0.4  # Lower threshold — Claude provides real filtering

for i, line in enumerate(lines):
    if "~~" in line:
        continue
    m = re.match(r"^(\s*[-*]\s+)(.+)", line)
    if not m:
        continue
    item_text = m.group(2).strip()
    clean_text = re.sub(r"[*_`\[\]()]", "", item_text).lower()
    words = [w for w in re.split(r"\W+", clean_text) if len(w) > 3]
    if not words:
        continue

    best_match = {"ratio": 0, "commits": []}
    for c in commits:
        msg_lower = c["message"].lower()
        matches = sum(1 for w in words if w in msg_lower)
        ratio = matches / len(words) if words else 0
        if ratio >= MATCH_THRESHOLD:
            # Get file-change summary (only lines with | showing files changed)
            stat_result = subprocess.run(
                ["git", "-C", repo_dir, "diff-tree", "--stat", "--no-commit-id", c["hash"]],
                capture_output=True, text=True
            )
            # Keep only file stat lines (contain |) and the summary line, cap at 8
            stat_lines = [l.strip() for l in stat_result.stdout.strip().split("\n")
                         if "|" in l or "changed" in l]
            stat = "\n".join(stat_lines[:8])
            best_match["commits"].append({
                "hash": c["hash"],
                "message": c["message"],
                "stat": stat
            })
            best_match["ratio"] = max(best_match["ratio"], ratio)

    if best_match["commits"]:
        # Keep only the top 3 most relevant commits per candidate
        candidates.append({
            "line_index": i,
            "item_text": item_text,
            "matched_commits": best_match["commits"][:3],
            "best_ratio": best_match["ratio"]
        })

# Sort by best match ratio (highest first) and cap at 15 candidates
candidates.sort(key=lambda c: c["best_ratio"], reverse=True)
MAX_CANDIDATES = 15
kept = candidates[:MAX_CANDIDATES]

for c in kept:
    print(f"  Candidate ({c['best_ratio']:.0%}): {c['item_text'][:70]}")

json.dump({"candidates": kept}, open(candidates_file, "w"), indent=2)
if kept:
    total = len(candidates)
    msg = f"\n{len(kept)} candidate(s) identified for Claude review"
    if total > MAX_CANDIDATES:
        msg += f" ({total - MAX_CANDIDATES} lower-confidence matches omitted)"
    print(msg)
else:
    print("No TODO items matched recent commits")
CANDIDATE_SCRIPT

    # Phase 2: Build audit review addendum for the worker prompt
    # Instead of a separate API call, the worker session reviews candidates
    # as part of its normal workflow (no extra cost).
    AUDIT_ADDENDUM_FILE="$SCRIPT_DIR/.audit_addendum.md"

    if [[ -f "$CANDIDATES_FILE" ]] && python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
sys.exit(0 if data.get('candidates') else 1)
" "$CANDIDATES_FILE" 2>/dev/null; then
        echo "Building audit review addendum for worker prompt..."

        python3 - "$CANDIDATES_FILE" "$AUDIT_ADDENDUM_FILE" << 'BUILD_ADDENDUM'
import json, sys

candidates_path = sys.argv[1]
addendum_path = sys.argv[2]

data = json.load(open(candidates_path))
candidates = data["candidates"]

addendum = """## Pre-task: Review Audit Candidates

Before picking a TODO item, review the following candidates that a keyword match
flagged as potentially addressed by recent commits. For each candidate, check
whether the commit message and changed files genuinely address the TODO item.

**Be conservative**: only mark an item as done if the commit clearly addresses it.
A commit that merely touches related files or uses similar words is NOT enough —
the commit message must indicate the specific work described in the TODO was done.

For each confirmed candidate, wrap the TODO item with `~~strikethrough~~` in
TODO.md (same format as step 9). Leave false positives untouched.

"""

for i, c in enumerate(candidates):
    addendum += f"### Candidate {i + 1}\n"
    addendum += f"**TODO item**: {c['item_text']}\n\n"
    for cm in c["matched_commits"]:
        addendum += f"- Commit `{cm['hash']}`: {cm['message']}\n"
        if cm.get("stat"):
            addendum += f"  ```\n"
            for line in cm["stat"].strip().split("\n"):
                addendum += f"  {line}\n"
            addendum += f"  ```\n"
    addendum += "\n"

addendum += "After reviewing all candidates, proceed with the normal workflow below.\n\n---\n\n"

with open(addendum_path, "w") as f:
    f.write(addendum)

print(f"  Audit addendum written with {len(candidates)} candidate(s)")
BUILD_ADDENDUM
    else
        # No candidates — ensure no stale addendum
        rm -f "$AUDIT_ADDENDUM_FILE"
    fi

    # Clean up candidates temp file
    rm -f "$CANDIDATES_FILE"

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

        # Pre-commit hooks (e.g., update-todo-patches) may modify TODO.md and
        # return exit 1 on first attempt. Retry once after re-staging.
        if ! git -C "$REPO_DIR" commit -m "chore: audit and clean up completed TODO items

Automated by claude-todo-worker pre-processing." 2>&1; then
            echo "Commit failed (likely pre-commit hook modified files). Re-staging and retrying..."
            git -C "$REPO_DIR" add -u 2>&1
            git -C "$REPO_DIR" commit -m "chore: audit and clean up completed TODO items

Automated by claude-todo-worker pre-processing." 2>&1 || echo "WARNING: Cleanup commit failed after retry"
        fi

        git -C "$REPO_DIR" push 2>&1 || echo "WARNING: Could not push cleanup commit (branch protection?)"
    fi

    # Record this run's timestamp
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$LAST_RUN_FILE"
    echo ""
fi

# ---------------------------------------------------------------------------
# Clean up stale artifacts from previous runs
# ---------------------------------------------------------------------------
cleanup_stale_artifacts() {
    echo ""
    echo "--- Cleaning up stale artifacts ---"
    local cleaned=0

    # 1. Remove old worktrees (not from today) that are safe to delete
    if [[ -d "$WORKTREE_BASE" ]]; then
        for wt_dir in "$WORKTREE_BASE"/*/; do
            [[ -d "$wt_dir" ]] || continue
            local wt_name
            wt_name=$(basename "$wt_dir")

            # Skip today's worktree(s)
            if [[ "$wt_name" == *"${DATE}"* ]]; then
                continue
            fi

            # Check if worktree has uncommitted changes
            if git -C "$wt_dir" status --porcelain 2>/dev/null | grep -q .; then
                echo "  Preserving $wt_name (uncommitted changes)"
                continue
            fi

            # Check if worktree has unpushed commits
            local wt_branch
            wt_branch=$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
            if [[ -n "$wt_branch" ]]; then
                local local_commits
                local_commits=$(git -C "$wt_dir" log --oneline "origin/$DEFAULT_BRANCH..HEAD" 2>/dev/null || echo "")
                local on_remote
                on_remote=$(git ls-remote --heads origin "$wt_branch" 2>/dev/null || echo "")

                if [[ -n "$local_commits" && -z "$on_remote" ]]; then
                    echo "  Preserving $wt_name (unpushed local-only commits)"
                    continue
                fi
            fi

            # Safe to remove
            echo "  Removing stale worktree: $wt_name"
            git worktree remove --force "$wt_dir" 2>/dev/null || rm -rf "$wt_dir"
            # Clean up local branch if it exists
            if [[ -n "$wt_branch" && "$wt_branch" != "HEAD" ]]; then
                git branch -D "$wt_branch" 2>/dev/null || true
            fi
            cleaned=$((cleaned + 1))
        done
    fi

    # 2. Delete remote branches for merged/closed PRs
    local remote_branches
    remote_branches=$(git branch -r 2>/dev/null | grep "origin/${BRANCH_PREFIX}/" | tr -d ' ' || true)
    for remote_ref in $remote_branches; do
        local branch_name="${remote_ref#origin/}"

        # Skip branches with open PRs
        if gh pr list --head "$branch_name" --state open --json number --jq 'length' 2>/dev/null | grep -q '^[1-9]'; then
            continue
        fi

        echo "  Deleting stale remote branch: $branch_name"
        git push origin --delete "$branch_name" 2>/dev/null || true
        cleaned=$((cleaned + 1))
    done

    # 3. Prune worktree metadata
    git worktree prune 2>/dev/null || true

    if [[ "$cleaned" -gt 0 ]]; then
        echo "  ✓ Cleaned $cleaned stale artifact(s)"
    else
        echo "  No stale artifacts found"
    fi
    echo ""
}

cleanup_stale_artifacts

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
            git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR"
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

# Prepend audit review addendum if candidates were found during pre-processing
AUDIT_ADDENDUM_FILE="$SCRIPT_DIR/.audit_addendum.md"
if [[ -f "$AUDIT_ADDENDUM_FILE" ]]; then
    echo "Including audit review addendum in prompt ($(wc -l < "$AUDIT_ADDENDUM_FILE") lines)"
    FULL_PROMPT="$(cat "$AUDIT_ADDENDUM_FILE")
${FULL_PROMPT}"
    rm -f "$AUDIT_ADDENDUM_FILE"
fi

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
    git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR"
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
