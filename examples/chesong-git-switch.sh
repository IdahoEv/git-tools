BRANCH=$1
WORKTREE_DIR="./worktrees/$BRANCH"
SYMLINK="./current"

if [ -z "$BRANCH" ]; then
  echo "Usage: $0 <branch-name>"
  exit 1
fi

# Creates worktree if it doesn't exist
if [ ! -d "$WORKTREE_DIR" ]; then
  echo "Creating worktree for branch $BRANCH..."
  git worktree add "$WORKTREE_DIR" "$BRANCH"
fi

# Updates symbolic link to point to this branch's worktree
echo "Updating symlink..."
ln -sfn "$WORKTREE_DIR" "$SYMLINK"
