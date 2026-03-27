#!/bin/bash
# Script for creating new git worktrees
#
# Usage:
#   .bcr/new-worktree.sh <worktree-name>
#   source .bcr/new-worktree.sh <worktree-name>
#
# IMPORTANT: To automatically `cd` into the new worktree, SOURCE this script:
#   source .bcr/new-worktree.sh my-feature
#   OR
#   . .bcr/new-worktree.sh my-feature
#
# Running it directly (./new-worktree.sh) will create the worktree but won't cd.

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Detect if script is being sourced
SOURCED=false
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    SOURCED=true
fi

# Get the main worktree directory (where this script lives)
if $SOURCED; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
MAIN_WORKTREE="$(dirname "$SCRIPT_DIR")"

echo -e "${BOLD}${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║       Git Worktree Setup Wizard        ║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

# Get worktree name from argument or prompt
if [ -n "${1:-}" ]; then
    WORKTREE_NAME="$1"
    echo -e "${BLUE}Worktree name:${NC} $WORKTREE_NAME"
else
    echo -e "${BLUE}Enter worktree name${NC} (used for directory name):"
    echo -e "${YELLOW}Examples: feature-login, fix-bug-123, experiment${NC}"
    read -r -p "> " WORKTREE_NAME

    if [ -z "$WORKTREE_NAME" ]; then
        echo -e "${RED}Error: Worktree name cannot be empty${NC}"
        if $SOURCED; then return 1; else exit 1; fi
    fi
fi

# Sanitize worktree name for directory
SANITIZED_NAME=$(echo "$WORKTREE_NAME" | sed 's/\//-/g' | sed 's/ /-/g')

# Auto-generate branch name: bcr/{YYMM}/{worktree name}
DATE_PREFIX=$(date +%y%m)
BRANCH_NAME="bcr/${DATE_PREFIX}/${SANITIZED_NAME}"

# Prompt for base branch (default: current branch)
CURRENT_BRANCH=$(git -C "$MAIN_WORKTREE" rev-parse --abbrev-ref HEAD)
echo ""
echo -e "${BLUE}Base branch${NC} [${CYAN}${CURRENT_BRANCH}${NC}]:"
read -r -p "> " BASE_BRANCH
BASE_BRANCH=${BASE_BRANCH:-$CURRENT_BRANCH}

# Determine worktree path
WORKTREE_PATH="$MAIN_WORKTREE/../$SANITIZED_NAME"

echo ""
echo -e "${BOLD}Configuration:${NC}"
echo -e "  Main worktree:  ${CYAN}$MAIN_WORKTREE${NC}"
echo -e "  New worktree:   ${CYAN}$WORKTREE_PATH${NC}"
echo -e "  Base branch:    ${CYAN}$BASE_BRANCH${NC}"
echo -e "  New branch:     ${CYAN}$BRANCH_NAME${NC}"
echo ""

# Confirm
read -r -p "Proceed with worktree creation? [Y/n] " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Cancelled.${NC}"
    if $SOURCED; then return 0; else exit 0; fi
fi

echo ""

# Check if worktree path already exists
if [ -d "$WORKTREE_PATH" ]; then
    echo -e "${RED}Error: Directory already exists: $WORKTREE_PATH${NC}"
    echo "Please remove it first or choose a different name."
    if $SOURCED; then return 1; else exit 1; fi
fi

# Create parent directory if needed
mkdir -p "$(dirname "$WORKTREE_PATH")"

# Create the worktree
echo -e "${BLUE}Creating worktree...${NC}"

# Navigate to main worktree for git commands
cd "$MAIN_WORKTREE"

# Check if branch exists locally
if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
    echo -e "${YELLOW}Branch '$BRANCH_NAME' already exists locally, checking it out...${NC}"
    git worktree add "$WORKTREE_PATH" "$BRANCH_NAME"
elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH_NAME"; then
    echo -e "${YELLOW}Branch '$BRANCH_NAME' exists on remote, checking it out...${NC}"
    git worktree add "$WORKTREE_PATH" -b "$BRANCH_NAME" "origin/$BRANCH_NAME"
else
    echo -e "${GREEN}Creating new branch '$BRANCH_NAME' from '$BASE_BRANCH'...${NC}"
    git worktree add "$WORKTREE_PATH" -b "$BRANCH_NAME" "$BASE_BRANCH"
fi

echo -e "${GREEN}✓${NC} Worktree created"
echo ""

# Copy configuration files
echo -e "${BLUE}Copying configuration files...${NC}"

# Symlink all .env* files that exist in the main worktree
ENV_COUNT=0
for envfile in "$MAIN_WORKTREE"/.env*; do
    [ -f "$envfile" ] || continue
    BASENAME="$(basename "$envfile")"
    ln -s "$envfile" "$WORKTREE_PATH/$BASENAME"
    echo -e "${GREEN}✓${NC} Symlinked $BASENAME"
    ENV_COUNT=$((ENV_COUNT + 1))
done
if [ "$ENV_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}⚠${NC} No .env* files found in main worktree"
fi

# Symlink .claude/settings.local.json if it exists
if [ -f "$MAIN_WORKTREE/.claude/settings.local.json" ]; then
    mkdir -p "$WORKTREE_PATH/.claude"
    ln -s "$MAIN_WORKTREE/.claude/settings.local.json" "$WORKTREE_PATH/.claude/settings.local.json"
    echo -e "${GREEN}✓${NC} Symlinked .claude/settings.local.json"
else
    echo -e "${YELLOW}⚠${NC} .claude/settings.local.json not found in main worktree"
fi

# Symlink .bcr directory
if [ -d "$MAIN_WORKTREE/.bcr" ]; then
    ln -s "$MAIN_WORKTREE/.bcr" "$WORKTREE_PATH/.bcr"
    echo -e "${GREEN}✓${NC} Symlinked .bcr"
else
    echo -e "${YELLOW}⚠${NC} .bcr not found in main worktree"
fi

echo ""

# Install dependencies
echo -e "${BLUE}Installing dependencies...${NC}"
(cd "$WORKTREE_PATH" && yarn install)
echo -e "${GREEN}✓${NC} Dependencies installed"

echo ""
echo -e "${GREEN}${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║       Worktree setup complete!         ║${NC}"
echo -e "${GREEN}${BOLD}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "Your new worktree is ready at:"
echo -e "${CYAN}$WORKTREE_PATH${NC}"
echo ""
