#!/bin/bash
# Restore Claude config from the public claude-config repo at session start.
#
# Self-healing behaviours:
# - Retries the clone 3 times with backoff (transient network resilience)
# - Updates this script itself from the repo (improvements propagate automatically)
# - Re-registers PreToolUse, PostToolBatch, and UserPromptSubmit hooks if
#   missing from settings.json (guards against the file being reset)
#
# Always exits 0 — never blocks session start.

REPO_URL="https://github.com/khbpb2vbgf-coder/claude-config"
CLAUDE_DIR="$HOME/.claude"

CLONE_DIR="$(mktemp -d)"
cleanup() { rm -rf "$CLONE_DIR"; }
trap cleanup EXIT

# Clone with retry (3 attempts, 2s / 4s backoff)
cloned=0
for attempt in 1 2 3; do
    if git clone --depth 1 "$REPO_URL" "$CLONE_DIR" 2>/dev/null; then
        cloned=1
        break
    fi
    echo "claude-config: clone attempt $attempt failed" >&2
    if [ "$attempt" -lt 3 ]; then
        sleep $((attempt * 2))
        rm -rf "$CLONE_DIR"
        CLONE_DIR="$(mktemp -d)"
    fi
done

if [ "$cloned" -eq 0 ]; then
    echo "claude-config: restore skipped after 3 failed attempts" >&2
    exit 0
fi

# Restore CLAUDE.md — skip if a symlink (kometa repo is authoritative source)
if [ ! -L "$CLAUDE_DIR/CLAUDE.md" ]; then
    cp "$CLONE_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null || true
fi

# Restore injection hook
mkdir -p "$CLAUDE_DIR/hooks"
cp "$CLONE_DIR/hooks/inject-constraints.py" "$CLAUDE_DIR/hooks/inject-constraints.py" 2>/dev/null || true
chmod +x "$CLAUDE_DIR/hooks/inject-constraints.py" 2>/dev/null || true

# Restore Stop hook git-check
cp "$CLONE_DIR/hooks/stop-hook-git-check.sh" "$CLAUDE_DIR/hooks/stop-hook-git-check.sh" 2>/dev/null || true
chmod +x "$CLONE_DIR/hooks/stop-hook-git-check.sh" 2>/dev/null || true

# Restore PreToolUse gate hook
cp "$CLONE_DIR/hooks/pre-tool-use-gate.sh" "$CLAUDE_DIR/hooks/pre-tool-use-gate.sh" 2>/dev/null || true
chmod +x "$CLAUDE_DIR/hooks/pre-tool-use-gate.sh" 2>/dev/null || true

# Restore PostToolBatch check hook
cp "$CLONE_DIR/hooks/post-tool-batch-check.sh" "$CLAUDE_DIR/hooks/post-tool-batch-check.sh" 2>/dev/null || true
chmod +x "$CLONE_DIR/hooks/post-tool-batch-check.sh" 2>/dev/null || true

# Self-update: replace this script with the repo's latest version
cp "$CLONE_DIR/hooks/restore-config.sh" "$CLAUDE_DIR/hooks/restore-config.sh" 2>/dev/null || true
chmod +x "$CLAUDE_DIR/hooks/restore-config.sh" 2>/dev/null || true

# Self-heal: re-register required hooks if missing from settings.json
python3 << 'PYEOF'
import json
import os
from pathlib import Path

settings_path = Path.home() / ".claude" / "settings.json"
if not settings_path.exists():
    exit(0)

try:
    with open(settings_path) as f:
        settings = json.load(f)
except (json.JSONDecodeError, OSError):
    exit(0)

hooks_dir = Path.home() / ".claude" / "hooks"
changed = False

# --- UserPromptSubmit: inject-constraints ---
hook_cmd = str(hooks_dir / "inject-constraints.py")
ups = settings.setdefault("hooks", {}).setdefault("UserPromptSubmit", [])
already = any(
    any(os.path.expanduser(h.get("command", "")) == hook_cmd for h in entry.get("hooks", []))
    for entry in ups
)
if not already:
    ups.append({"hooks": [{"type": "command", "command": hook_cmd}]})
    print("claude-config: UserPromptSubmit inject-constraints hook re-registered")
    changed = True

# --- PreToolUse: pre-tool-use-gate ---
gate_cmd = str(hooks_dir / "pre-tool-use-gate.sh")
ptu = settings["hooks"].setdefault("PreToolUse", [])
already = any(
    any(os.path.expanduser(h.get("command", "")) == gate_cmd for h in entry.get("hooks", []))
    for entry in ptu
)
if not already:
    ptu.append({"hooks": [{"type": "command", "command": gate_cmd, "timeout": 10}]})
    print("claude-config: PreToolUse gate hook re-registered")
    changed = True

# --- PostToolBatch: post-tool-batch-check ---
batch_cmd = str(hooks_dir / "post-tool-batch-check.sh")
ptb = settings["hooks"].setdefault("PostToolBatch", [])
already = any(
    any(os.path.expanduser(h.get("command", "")) == batch_cmd for h in entry.get("hooks", []))
    for entry in ptb
)
if not already:
    ptb.append({"hooks": [{"type": "command", "command": batch_cmd, "timeout": 10}]})
    print("claude-config: PostToolBatch check hook re-registered")
    changed = True

if changed:
    try:
        with open(settings_path, "w") as f:
            json.dump(settings, f, indent=4)
    except OSError:
        pass
PYEOF

echo "claude-config: restore complete"
exit 0
