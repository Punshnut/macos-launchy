#!/bin/bash
# Publishes wiki/ to the GitHub wiki repo (macos-launchy.wiki.git) via git subtree.
set -euo pipefail

cd "$(dirname "$0")/.."

REMOTE_NAME="wiki"
REMOTE_URL="https://github.com/Punshnut/macos-launchy.wiki.git"
BRANCH="master"

if ! git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
  echo "Adding '$REMOTE_NAME' remote..."
  git remote add "$REMOTE_NAME" "$REMOTE_URL"
fi

git fetch "$REMOTE_NAME"
git subtree push --prefix=wiki "$REMOTE_NAME" "$BRANCH"

echo "Wiki published: https://github.com/Punshnut/macos-launchy/wiki"
