#!/bin/bash
# Restore Claude config from the public claude-config repo at session start.
#
# Self-healing behaviours:
# - Retries the clone 3 times with backoff (transient network resilience)
# - Updates this script itself from the repo (improvements propagate automatically)
# - Re-registers the UserPromptSubmit injection hook if missing from
#   launcher-settings.json (survives CCR resets of that file)
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

# Restore CLAUDE.md
cp "$CLONE_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null || true

# Restore injection hook
mkdir -p "$CLAUDE_DIR/hooks"
cp "$CLONE_DIR/hooks/inject-constraints.py" "$CLAUDE_DIR/hooks/inject-constraints.py" 2>/dev/null || true
chmod +x "$CLAUDE_DIR/hooks/inject-constraints.py" 2>/dev/null || true

# Self-update: replace this script with the repo's latest version
cp "$CLONE_DIR/hooks/restore-config.sh" "$CLAUDE_DIR/hooks/restore-config.sh" 2>/dev/null || true
chmod +x "$CLAUDE_DIR/hooks/restore-config.sh" 2>/dev/null || true

# Self-heal: re-register UserPromptSubmit hook if missing from launcher-settings.json
# (guards against CCR resetting the file to a baseline without our hook entry)
python3 - <<'PYEOF'
import json
from pathlib import Path

settings_path = Path.home() / ".claude" / "launcher-settings.json"
if not settings_path.exists():
    exit(0)

try:
    with open(settings_path) as f:
        settings = json.load(f)
except (json.JSONDecodeError, OSError):
    exit(0)

hook_cmd = "/root/.claude/hooks/inject-constraints.py"
ups = settings.setdefault("hooks", {}).setdefault("UserPromptSubmit", [])

already = any(
    any(h.get("command") == hook_cmd for h in entry.get("hooks", []))
    for entry in ups
)

if not already:
    ups.append({"hooks": [{"type": "command", "command": hook_cmd}]})
    try:
        with open(settings_path, "w") as f:
            json.dump(settings, f, indent=4)
        print("claude-config: UserPromptSubmit hook re-registered")
    except OSError:
        pass
PYEOF

echo "claude-config: restore complete"
exit 0
