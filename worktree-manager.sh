#!/bin/bash
# worktree-manager.sh - Create and configure git worktrees with automatic setup
#
# Usage:
#   worktree-manager.sh --init                             # Convert regular repo to worktree structure
#   worktree-manager.sh [--claude]                         # Interactive mode: select branch with fzf
#   worktree-manager.sh [--claude] <branch-name>           # Create worktree with arbitrary branch name
#   worktree-manager.sh [--claude] --sc <ticket-id>        # Create worktree from Shortcut ticket
#
# Aliases (when shell module is loaded):
#   wm          worktree-manager.sh
#   wms         worktree-manager.sh --sc
#   wmc         worktree-manager.sh --claude
#   wmsc        worktree-manager.sh --claude --sc
#
# Options:
#   --init      Convert a regular git repository into worktree structure
#   --claude    Open Claude Code in the worktree after setup
#   --sc        Use Shortcut ticket ID to fetch branch name and details
#
# Examples:
#   wm --init                   # Initialize worktree structure (run in repo root)
#   wm                          # Interactive: select from branches/worktrees
#   wmc                         # Interactive + open Claude
#   wm feature/add-login        # Create specific branch
#   wms 65682                   # Create from Shortcut ticket
#   wmsc 65682                  # Shortcut + open Claude

set -e

# Command substitutions run in a subshell that does NOT inherit errexit
# unless this is enabled (bash >= 4.4; macOS system bash is 3.2 and lacks
# this option, hence the guard). Without it, a failing command inside a
# function called as `x=$(fn ...)` silently falls through to the rest of
# that function instead of aborting - which is why the explicit `|| error`
# checks below don't rely on this alone.
shopt -s inherit_errexit 2>/dev/null || true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
TICKET_FILE=".ticket.local.md"

# ============================================================================
# Utility Functions
# ============================================================================

error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${BLUE}$1${NC}" >&2
}

success() {
    echo -e "${GREEN}✓${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}⚠${NC} $1" >&2
}

# Check if a file/directory is tracked by git
is_tracked() {
    local path="$1"
    git ls-files --error-unmatch "$path" >/dev/null 2>&1
}

# ============================================================================
# Git Repository Detection and Initialization
# ============================================================================

# Check if current directory is a worktree-enabled repository
is_worktree_repo() {
    local worktree_count
    worktree_count=$(git worktree list 2>/dev/null | wc -l | tr -d ' ')

    # If there's more than 1 worktree, it's been initialized
    [ "$worktree_count" -gt 1 ]
}

# Initialize a regular git repository into worktree structure
init_worktree_structure() {
    # Must be in a git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        error "Not in a git repository. Run this command from a git repository root."
    fi

    # Check if already a worktree setup
    if is_worktree_repo; then
        error "This repository is already using worktrees. No initialization needed."
    fi

    # Must be in the root of the repository (not a subdirectory)
    # Both sides are resolved with -P so a symlink component in the cwd
    # (e.g. macOS /tmp -> /private/tmp) doesn't cause a false mismatch.
    local git_root
    git_root=$(git rev-parse --show-toplevel)
    local current_dir
    current_dir=$(pwd -P)

    if [ "$git_root" != "$current_dir" ]; then
        error "Must run --init from the repository root: $git_root"
    fi

    # Get the current branch name
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)

    # Ensure working directory is clean
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        error "Working directory has uncommitted changes. Commit or stash them before running --init"
    fi

    info "Converting repository to worktree structure..."
    info "Current branch: ${current_branch}"

    # Sanitize branch name for directory (replace slashes with dashes)
    local main_dir_name
    main_dir_name=$(echo "$current_branch" | sed 's/\//-/g')
    local repo_name
    repo_name=$(basename "$current_dir")
    local parent_dir
    parent_dir=$(dirname "$current_dir")

    echo ""
    echo -e "${YELLOW}This will:${NC}"
    echo -e "  1. Clone current repo as bare to: ${repo_name}/.git"
    echo -e "  2. Create main worktree at: ${repo_name}/${main_dir_name}"
    echo -e "  3. Enable sibling worktrees: ${repo_name}/<sanitized-branch-name>"
    echo -e "  (Branch: ${current_branch} → Directory: ${main_dir_name})"
    echo ""

    read -r -p "Proceed with initialization? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        error "Initialization cancelled"
    fi

    # `git clone --bare` from a local path points the new repo's remotes at
    # that local path, not at the original upstream URLs. Capture the real
    # URLs now so they can be restored after the clone.
    local remote_names
    remote_names=$(git remote)
    local remote_backup=()
    local remote
    for remote in $remote_names; do
        local fetch_url push_url
        fetch_url=$(git remote get-url "$remote")
        push_url=$(git remote get-url --push "$remote" 2>/dev/null || echo "$fetch_url")
        remote_backup+=("${remote}|${fetch_url}|${push_url}")
    done

    # Create a temporary directory for the bare repository
    local temp_bare="${parent_dir}/.${repo_name}.bare.$$"

    info "Creating bare repository..."

    # Clone the current repo as bare to temp location
    git clone --bare "$current_dir" "$temp_bare"

    # Change to parent directory before moving current directory
    # (avoids shell being in a deleted directory)
    cd "$parent_dir"

    # Move the old directory out of the way
    info "Reorganizing directories..."
    mv "$current_dir" "${current_dir}.old"

    # Create new structure directory
    mkdir -p "$current_dir"

    # Move bare repo into final location
    mv "$temp_bare" "${current_dir}/.git"

    # Restore the real remote URLs (the bare clone pointed them at the
    # now-obsolete local path instead)
    for entry in "${remote_backup[@]}"; do
        IFS='|' read -r remote fetch_url push_url <<< "$entry"
        git -C "${current_dir}/.git" remote set-url "$remote" "$fetch_url"
        if [ "$push_url" != "$fetch_url" ]; then
            git -C "${current_dir}/.git" remote set-url --push "$remote" "$push_url"
        fi
    done

    # Now add the first worktree from the final location
    info "Creating main worktree..."
    git -C "${current_dir}/.git" worktree add "${current_dir}/${main_dir_name}" "$current_branch"

    # A bare clone copies branches directly into refs/heads rather than as
    # remote-tracking branches, so upstream tracking is never set up. Restore
    # it for the main branch if origin is one of the restored remotes.
    if git -C "${current_dir}/.git" remote get-url origin >/dev/null 2>&1; then
        git -C "${current_dir}/${main_dir_name}" config "branch.${current_branch}.remote" origin
        git -C "${current_dir}/${main_dir_name}" config "branch.${current_branch}.merge" "refs/heads/${current_branch}"
    fi

    # Clean up old directory
    rm -rf "${current_dir}.old"

    echo ""
    success "Repository converted to worktree structure!"
    echo ""
    echo -e "${CYAN}Repository root:${NC} ${current_dir}"
    echo -e "${CYAN}Main worktree:${NC} ${current_dir}/${main_dir_name}"
    echo ""
    echo -e "${YELLOW}IMPORTANT:${NC} Your shell is no longer in a valid directory."
    echo -e "${YELLOW}Run this command:${NC}"
    echo -e "  ${CYAN}cd ${current_dir}/${main_dir_name}${NC}"
    echo ""
}

# Find the main worktree directory
#
# `git worktree list` always lists the bare repo itself first once a repo has
# been converted via --init, so the naive "head -1" picks the bare container
# (no checked-out files) instead of an actual worktree. Skip bare entries.
# Also skip "prunable" entries - git flags these when a worktree's directory
# was deleted directly (e.g. `rm -rf`) instead of via `git worktree remove`,
# leaving orphaned metadata that would otherwise get picked as the "main"
# worktree despite pointing at a directory that no longer exists.
find_main_worktree() {
    git rev-parse --git-dir >/dev/null 2>&1 || error "Not in a git repository"

    local stale_count
    stale_count=$(git worktree list --porcelain | grep -c '^prunable' || true)
    if [ "$stale_count" -gt 0 ]; then
        warning "Found ${stale_count} stale worktree entr$([ "$stale_count" -eq 1 ] && echo y || echo ies) (directory removed without 'git worktree remove'). Run 'git worktree prune' to clean up."
    fi

    git worktree list --porcelain | awk '
        /^worktree / { path = substr($0, 10); bare = 0; prunable = 0 }
        /^bare$/ { bare = 1 }
        /^prunable/ { prunable = 1 }
        /^$/ {
            if (path != "" && !bare && !prunable && !found) { print path; found = 1 }
            path = ""
        }
        END {
            if (path != "" && !bare && !prunable && !found) print path
        }
    '
}

# Validate that we're in a worktree-enabled repository
validate_worktree_repo() {
    if ! is_worktree_repo; then
        echo ""
        error "This repository is not using worktrees yet.

Initialize it first with:
    ${0} --init

Or if you're in a worktree subdirectory, navigate to a worktree root."
    fi
}

# Detect the primary branch name (main, master, or development)
detect_primary_branch() {
    local main_worktree="$1"

    # Try to detect from current branch of main worktree
    local current_branch
    current_branch=$(git -C "$main_worktree" rev-parse --abbrev-ref HEAD 2>/dev/null) || true

    # Check if it's one of the common primary branch names
    if [[ "$current_branch" =~ ^(main|master|development)$ ]]; then
        echo "$current_branch"
        return
    fi

    # Otherwise, check which of these branches exist
    for branch in main master development; do
        if git -C "$main_worktree" rev-parse --verify "$branch" >/dev/null 2>&1; then
            echo "$branch"
            return
        fi
    done

    # Fallback to current branch - but if HEAD lookup itself failed and no
    # standard primary branch exists either, there's nothing usable to base
    # a new worktree's branch on, so fail loudly instead of handing back "".
    if [ -z "$current_branch" ]; then
        error "Could not determine a base branch for worktree at '$main_worktree' (HEAD lookup failed and none of main/master/development exist)"
    fi
    echo "$current_branch"
}

# ============================================================================
# Shortcut Integration
# ============================================================================

# Fetch ticket details from Shortcut and generate branch name
fetch_shortcut_ticket() {
    local ticket_id="$1"

    # Check if short CLI is available
    if ! command -v short >/dev/null 2>&1; then
        error "'short' CLI not found. Install with: brew install short"
    fi

    info "Fetching Shortcut ticket #${ticket_id}..."

    # Get the git branch name format from Shortcut
    local branch_name
    branch_name=$(short story "$ticket_id" --git-branch-short --quiet 2>/dev/null | grep "^Switched to" | sed 's/Switched to a new branch //' | tr -d "'\"" || true)

    if [ -z "$branch_name" ]; then
        # Fallback: try to construct it manually
        branch_name="sc-${ticket_id}"
        warning "Could not auto-generate branch name, using: $branch_name"
    fi

    echo "$branch_name"
}

# Fetch and save ticket details to markdown file
save_ticket_details() {
    local ticket_id="$1"
    local worktree_path="$2"
    local ticket_file="${worktree_path}/${TICKET_FILE}"

    info "Fetching ticket details..."

    # Fetch full story details
    local story_output
    story_output=$(short story "$ticket_id" --quiet 2>/dev/null || echo "")

    if [ -z "$story_output" ]; then
        warning "Could not fetch ticket details for #${ticket_id}"
        return
    fi

    # Save to file
    {
        echo "# Shortcut Story #${ticket_id}"
        echo ""
        echo "Fetched: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "---"
        echo ""
        echo "$story_output"
    } > "$ticket_file"

    success "Saved ticket details to ${TICKET_FILE}"
}

# ============================================================================
# Worktree and Branch Detection
# ============================================================================

# Interactive branch/worktree selector using fzf
select_branch_interactive() {
    # Check if fzf is available
    if ! command -v fzf >/dev/null 2>&1; then
        error "fzf not found. Install with: brew install fzf"
    fi

    info "Loading branches and worktrees..."

    # Build a list of worktrees with their branches
    local worktrees_list=""
    worktrees_list=$(git worktree list --porcelain | awk '
        /^worktree / { path = substr($0, 10) }
        /^branch / {
            branch = substr($0, 8)
            gsub(/^refs\/heads\//, "", branch)
            printf "[worktree] %s\n", branch
        }
    ')

    # Get all local branches not in worktrees
    local local_branches=""
    local_branches=$(git branch --format='%(refname:short)' | while read -r branch; do
        if ! echo "$worktrees_list" | grep -q "\\[worktree\\] $branch"; then
            echo "[local] $branch"
        fi
    done)

    # Get remote branches not in local or worktrees
    local remote_branches=""
    remote_branches=$(git branch -r --format='%(refname:short)' | grep '^origin/' | sed 's|^origin/||' | while read -r branch; do
        # Skip HEAD and branches that exist locally or in worktrees
        if [ "$branch" = "HEAD" ]; then
            continue
        fi
        if ! echo "$worktrees_list" | grep -q "\\[worktree\\] $branch"; then
            if ! git show-ref --verify --quiet "refs/heads/$branch"; then
                echo "[remote] $branch"
            fi
        fi
    done)

    # Combine and present with fzf
    {
        echo "$worktrees_list"
        echo "$local_branches"
        echo "$remote_branches"
    } | fzf \
        --prompt="Select branch or worktree: " \
        --height=50% \
        --border \
        --preview="echo {} | sed 's/^\[[^]]*\] //' | xargs -I@ sh -c 'git log --oneline --graph --color=always -10 @ 2>/dev/null || echo \"Branch: @\"'" \
        --preview-window=right:50% | sed 's/^\[[^]]*\] //'
}

# Check if a worktree already exists for the given branch
find_existing_worktree() {
    local branch_name="$1"

    # Get all worktrees and their branches
    git worktree list --porcelain | awk '
        /^worktree / { path = substr($0, 10) }
        /^branch / {
            branch = substr($0, 8)
            gsub(/^refs\/heads\//, "", branch)
            if (branch == "'"$branch_name"'") {
                print path
                exit
            }
        }
    '
}

# Check if branch exists and return its status
check_branch_exists() {
    local branch_name="$1"

    # Check for existing worktree first
    if git worktree list --porcelain | grep -q "branch refs/heads/$branch_name"; then
        echo "worktree"
        return 0
    fi

    # Check local branches
    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
        echo "local"
        return 0
    fi

    # Check remote branches
    if git show-ref --verify --quiet "refs/remotes/origin/$branch_name"; then
        echo "remote"
        return 0
    fi

    echo "none"
    return 1
}

# ============================================================================
# Worktree Creation
# ============================================================================

create_or_use_worktree() {
    local branch_name="$1"
    local base_branch="$2"
    local main_worktree="$3"
    local is_new_worktree=true

    # Determine project root (parent of main worktree)
    local project_root
    project_root=$(dirname "$main_worktree")

    # Sanitize branch name for directory (replace slashes with dashes)
    local dir_name
    dir_name=$(echo "$branch_name" | sed 's/\//-/g')

    local worktree_path="${project_root}/${dir_name}"

    # Check branch/worktree existence. check_branch_exists legitimately
    # returns 1 for the "none" status (branch doesn't exist yet) - under
    # set -e, capturing that via a bare assignment would kill the script
    # right here, which is exactly the common case of creating a new branch.
    local branch_status
    branch_status=$(check_branch_exists "$branch_name") || true

    case "$branch_status" in
        worktree)
            # Worktree already exists for this branch
            local existing_path
            existing_path=$(find_existing_worktree "$branch_name")
            info "Worktree already exists for branch '$branch_name'"
            echo -e "${CYAN}Location:${NC} ${existing_path}" >&2
            echo "$existing_path"
            is_new_worktree=false
            return 0
            ;;
        local)
            # Branch exists locally, create worktree from it
            info "Branch '$branch_name' exists locally, creating worktree..."
            git worktree add "$worktree_path" "$branch_name" 1>&2 \
                || error "git worktree add failed for branch '$branch_name'"
            ;;
        remote)
            # Branch exists on remote, check it out
            info "Branch '$branch_name' exists on remote, creating worktree..."
            git worktree add "$worktree_path" -b "$branch_name" "origin/$branch_name" 1>&2 \
                || error "git worktree add failed for branch '$branch_name' from 'origin/$branch_name'"
            ;;
        none)
            # Create new branch
            info "Creating new branch '$branch_name' from '$base_branch'..."
            git worktree add "$worktree_path" -b "$branch_name" "$base_branch" 1>&2 \
                || error "git worktree add failed for new branch '$branch_name' from '$base_branch'"
            ;;
    esac

    # git worktree add can print a fatal error yet still be masked by callers
    # capturing this function's output via command substitution (see the
    # inherit_errexit note near the top) - so don't trust its exit status
    # alone, confirm the directory actually exists before declaring success.
    [ -d "$worktree_path" ] || error "Worktree directory was not created: $worktree_path"

    success "Worktree ready"
    echo "$worktree_path"
}

# ============================================================================
# Configuration Symlinking
# ============================================================================

symlink_configuration() {
    local main_worktree="$1"
    local worktree_path="$2"

    info "Setting up configuration..."

    local symlinked=0

    # Symlink .env* files
    for envfile in "$main_worktree"/.env*; do
        [ -f "$envfile" ] || continue

        local basename
        basename="$(basename "$envfile")"

        # Check if it's tracked
        if ! is_tracked "$envfile"; then
            ln -s "$envfile" "$worktree_path/$basename"
            success "Symlinked $basename"
            ((symlinked++))
        fi
    done

    # Check .claude directory
    if [ -d "$main_worktree/.claude" ]; then
        if ! is_tracked "$main_worktree/.claude"; then
            # Entire directory is untracked, symlink it
            ln -s "$main_worktree/.claude" "$worktree_path/.claude"
            success "Symlinked .claude/"
            ((symlinked++))
        else
            # Directory is tracked, but check for settings.local.json
            if [ -f "$main_worktree/.claude/settings.local.json" ]; then
                if ! is_tracked "$main_worktree/.claude/settings.local.json"; then
                    mkdir -p "$worktree_path/.claude"
                    ln -s "$main_worktree/.claude/settings.local.json" "$worktree_path/.claude/settings.local.json"
                    success "Symlinked .claude/settings.local.json"
                    ((symlinked++))
                fi
            fi
        fi
    fi

    # Symlink docs/local if it exists
    if [ -d "$main_worktree/docs/local" ]; then
        mkdir -p "$worktree_path/docs"
        ln -s "$main_worktree/docs/local" "$worktree_path/docs/local"
        success "Symlinked docs/local/"
        ((symlinked++))
    fi

    if [ $symlinked -eq 0 ]; then
        warning "No configuration files found to symlink"
    fi
}

# ============================================================================
# Dependency Installation
# ============================================================================

install_dependencies() {
    local worktree_path="$1"

    # Check for package.json
    if [ ! -f "$worktree_path/package.json" ]; then
        return
    fi

    # Check if node_modules already exists
    if [ -d "$worktree_path/node_modules" ]; then
        warning "node_modules already exists, skipping installation"
        return
    fi

    info "Installing dependencies..."

    # Detect package manager
    local pm="npm"
    if [ -f "$worktree_path/yarn.lock" ]; then
        pm="yarn"
    elif [ -f "$worktree_path/pnpm-lock.yaml" ]; then
        pm="pnpm"
    fi

    # Run installation
    (cd "$worktree_path" && $pm install)
    success "Dependencies installed with $pm"
}

# ============================================================================
# Main
# ============================================================================

main() {
    local branch_name=""
    local ticket_id=""
    local use_shortcut=false
    local open_claude=false
    local interactive_mode=false

    # Parse arguments
    if [ $# -eq 0 ]; then
        # No arguments - enter interactive mode
        interactive_mode=true
    else
        # Check for --init flag first
        if [ "$1" = "--init" ]; then
            init_worktree_structure
            exit 0
        fi

        # Check for --claude flag
        if [ "$1" = "--claude" ]; then
            open_claude=true
            shift
        fi

        # Check if we still have arguments after consuming --claude
        if [ $# -eq 0 ]; then
            interactive_mode=true
        elif [ "$1" = "--sc" ]; then
            if [ -z "${2:-}" ]; then
                error "Shortcut ticket ID required after --sc"
            fi
            use_shortcut=true
            ticket_id="$2"
        else
            branch_name="$1"
        fi
    fi

    # Validate that we're in a worktree-enabled repository
    validate_worktree_repo

    # Find main worktree
    local main_worktree
    main_worktree=$(find_main_worktree)
    info "Main worktree: ${main_worktree}"

    # Detect primary branch for base
    local base_branch
    base_branch=$(detect_primary_branch "$main_worktree")
    info "Base branch: ${base_branch}"

    # Interactive mode - let user select branch
    if [ "$interactive_mode" = true ]; then
        branch_name=$(select_branch_interactive)
        if [ -z "$branch_name" ]; then
            error "No branch selected"
        fi
        info "Selected: ${branch_name}"
    # If using Shortcut, fetch the branch name
    elif [ "$use_shortcut" = true ]; then
        branch_name=$(fetch_shortcut_ticket "$ticket_id")
        info "Branch name: ${branch_name}"
    else
        info "Branch name: ${branch_name}"
    fi

    # Check if worktree already exists (see the note on check_branch_exists's
    # "none" return status in create_or_use_worktree for why `|| true` matters)
    local branch_status
    branch_status=$(check_branch_exists "$branch_name") || true

    local worktree_path
    local is_existing=false

    if [ "$branch_status" = "worktree" ]; then
        # Worktree already exists, just return its path
        is_existing=true
        worktree_path=$(find_existing_worktree "$branch_name")
        info "Worktree already exists for branch '$branch_name'"

        # Still save/update ticket details if using Shortcut
        if [ "$use_shortcut" = true ]; then
            save_ticket_details "$ticket_id" "$worktree_path"
        fi
    else
        # Create or checkout worktree
        worktree_path=$(create_or_use_worktree "$branch_name" "$base_branch" "$main_worktree")

        # Only do setup for newly created worktrees
        symlink_configuration "$main_worktree" "$worktree_path"
        install_dependencies "$worktree_path"

        # Save ticket details if using Shortcut
        if [ "$use_shortcut" = true ]; then
            save_ticket_details "$ticket_id" "$worktree_path"
        fi
    fi

    # Final output
    echo ""
    if [ "$is_existing" = true ]; then
        echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}${BOLD}  Existing worktree found${NC}"
        echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}${BOLD}  Worktree ready!${NC}"
        echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi
    echo ""
    echo -e "${CYAN}Location:${NC} ${worktree_path}"
    echo -e "${CYAN}Branch:${NC}   ${branch_name}"
    echo ""

    # Open Claude if requested
    if [ "$open_claude" = true ]; then
        info "Opening Claude Code..."
        (cd "$worktree_path" && claude >/dev/null 2>&1 &)
        success "Claude Code launched"
        if [ "$use_shortcut" = true ]; then
            echo -e "${YELLOW}Note:${NC} Review ${TICKET_FILE} for ticket details in Claude"
        fi
    else
        echo -e "${YELLOW}Next steps:${NC}"
        echo -e "  cd ${worktree_path}"
        echo -e "  claude"
        if [ "$use_shortcut" = true ]; then
            echo -e "  # Review ${TICKET_FILE} for ticket details"
        fi
    fi
    echo ""

    # Print path for scripting use
    echo "$worktree_path"
}

main "$@"
