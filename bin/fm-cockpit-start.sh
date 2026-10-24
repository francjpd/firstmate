#!/usr/bin/env bash
# bin/fm-cockpit-start.sh - autonomous task dispatch trigger from the cockpit
#
# Usage:
#   bin/fm-cockpit-start.sh <task-id>
#
# When the captain triggers start on a task in deck-axi or backlog-axi:
# 1. Updates task state to in_flight in the backlog.
# 2. Inspects task metadata (repo, kind, title, body).
# 3. Resolves project directory and registered delivery mode.
# 4. Scaffolds data/<task-id>/brief.md if not already created, filling
#    Captain's intent and Firstmate spec.
# 5. Spawns an autonomous worker via bin/fm-spawn.sh into an isolated worktree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

TASK_ID="${1:-}"
if [ -z "$TASK_ID" ]; then
  echo "Usage: fm-cockpit-start.sh <task-id>" >&2
  exit 1
fi

BACKLOG_FILE="$DATA/backlog.md"
if [ ! -f "$BACKLOG_FILE" ]; then
  echo "error: backlog file not found at $BACKLOG_FILE" >&2
  exit 1
fi

# 1. Update task state to in_flight if not already in_flight
if command -v tasks-axi >/dev/null 2>&1; then
  tasks-axi start "$TASK_ID" --file "$BACKLOG_FILE" 2>/dev/null || true
fi

# 2. Check if a worker for this task is already running
if [ -f "$STATE/${TASK_ID}.meta" ]; then
  if "$SCRIPT_DIR/fm-control.sh" status "$TASK_ID" >/dev/null 2>&1; then
    echo "Worker for $TASK_ID is already active."
    exit 0
  fi
fi

# 3. Parse task metadata from backlog using python3
TASK_INFO=$(python3 -c '
import os, sys, re, json

backlog_file = sys.argv[1]
task_id = sys.argv[2]

with open(backlog_file, "r", encoding="utf-8") as f:
    content = f.read()

pattern = rf"^[ \t]*-[ \t]*\[[ x]\][ \t]*({re.escape(task_id)})[ \t]*-[ \t]*(.*?)(?=^[ \t]*-[ \t]*\[|\Z)"
match = re.search(pattern, content, re.MULTILINE | re.DOTALL)
if not match:
    print(json.dumps({"error": f"task {task_id} not found in backlog"}))
    sys.exit(0)

first_line = match.group(2).split("\n")[0].strip()
body_lines = [l.strip() for l in match.group(2).split("\n")[1:] if l.strip()]
body = "\n".join(body_lines)

repo_match = re.search(r"\(repo:\s*([^)]+)\)", first_line)
kind_match = re.search(r"\(kind:\s*([^)]+)\)", first_line)

repo = repo_match.group(1).strip() if repo_match else "firstmate"
kind = kind_match.group(1).strip() if kind_match else "ship"

clean_title = re.sub(r"\(repo:\s*[^)]+\)", "", first_line)
clean_title = re.sub(r"\(kind:\s*[^)]+\)", "", clean_title)
clean_title = re.sub(r"\(since:\s*[^)]+\)", "", clean_title).strip()

print(json.dumps({
    "id": task_id,
    "repo": repo,
    "kind": kind,
    "title": clean_title,
    "body": body
}))
' "$BACKLOG_FILE" "$TASK_ID")

ERROR=$(echo "$TASK_INFO" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("error", ""))')
if [ -n "$ERROR" ]; then
  echo "error: $ERROR" >&2
  exit 1
fi

REPO=$(echo "$TASK_INFO" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("repo", "firstmate"))')
KIND=$(echo "$TASK_INFO" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("kind", "ship"))')
TITLE=$(echo "$TASK_INFO" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("title", ""))')
BODY=$(echo "$TASK_INFO" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("body", ""))')

# 4. Resolve project directory and delivery mode
if [ "$REPO" = "firstmate" ]; then
  PROJECT_DIR="$FM_ROOT"
  MODE="local-only"
  YOLO="off"
else
  # Resolve from data/projects.md
  read -r MODE YOLO < <("$SCRIPT_DIR/fm-project-mode.sh" "$REPO" 2>/dev/null || echo "direct-PR off")
  # Determine local clone dir
  if [ -d "$FM_HOME/projects/$REPO" ]; then
    PROJECT_DIR="$FM_HOME/projects/$REPO"
  elif [ -d "$HOME/Projects/$REPO" ]; then
    PROJECT_DIR="$HOME/Projects/$REPO"
  elif [ -d "$HOME/Projects/hope/$REPO" ]; then
    PROJECT_DIR="$HOME/Projects/hope/$REPO"
  else
    PROJECT_DIR="$FM_HOME/projects/$REPO"
  fi
fi

# 5. Scaffold data/<task-id>/brief.md if missing
BRIEF_DIR="$DATA/$TASK_ID"
BRIEF_FILE="$BRIEF_DIR/brief.md"

if [ ! -f "$BRIEF_FILE" ]; then
  mkdir -p "$BRIEF_DIR"
  if [ "$KIND" = "scout" ]; then
    "$SCRIPT_DIR/fm-brief.sh" "$TASK_ID" "$REPO" --scout >/dev/null
  else
    "$SCRIPT_DIR/fm-brief.sh" "$TASK_ID" "$REPO" --mode "$MODE" --project "$PROJECT_DIR" >/dev/null
  fi

  # Replace {TASK} and {FIRSTMATE_SPEC} placeholders
  python3 -c '
import sys

brief_file = sys.argv[1]
title = sys.argv[2]
body = sys.argv[3]

with open(brief_file, "r", encoding="utf-8") as f:
    text = f.read()

spec_text = body if body else title
text = text.replace("{TASK}", title)
text = text.replace("{FIRSTMATE_SPEC}", spec_text)

with open(brief_file, "w", encoding="utf-8") as f:
    f.write(text)
' "$BRIEF_FILE" "$TITLE" "$BODY"
fi

# 6. Spawn worker via fm-spawn.sh
echo "Dispatched from cockpit: spawning worker for $TASK_ID ($REPO, mode=$MODE)..."
if [ "$KIND" = "scout" ]; then
  exec "$SCRIPT_DIR/fm-spawn.sh" "$TASK_ID" "$PROJECT_DIR" --scout
else
  exec "$SCRIPT_DIR/fm-spawn.sh" "$TASK_ID" "$PROJECT_DIR" --mode "$MODE" --yolo "$YOLO"
fi
