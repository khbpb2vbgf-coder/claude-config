#!/bin/bash
# Restore Claude config from the claude-config repo at session start.
# Keeps CLAUDE.md and the injection hook in sync with the repo on every session.
# Exits 0 on any failure — never blocks session start.

REPO_URL="https://github.com/khbpb2vbgf-coder/claude-config"
CLONE_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$CLONE_DIR"
}
trap cleanup EXIT

git clone --depth 1 "$REPO_URL" "$CLONE_DIR" 2>/dev/null || {
    echo "claude-config: restore skipped (repo not reachable)" >&2
    exit 0
}

cp "$CLONE_DIR/CLAUDE.md" "$HOME/.claude/CLAUDE.md" 2>/dev/null || true

mkdir -p "$HOME/.claude/hooks"
cp "$CLONE_DIR/hooks/inject-constraints.py" "$HOME/.claude/hooks/inject-constraints.py" 2>/dev/null || true
chmod +x "$HOME/.claude/hooks/inject-constraints.py" 2>/dev/null || true

echo "claude-config: CLAUDE.md and inject-constraints.py restored"
exit 0
