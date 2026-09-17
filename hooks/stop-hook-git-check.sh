#!/bin/bash
#
# Stop hook: informational, non-blocking check for uncommitted git changes
# in the session's current working directory.
#
# Contract (Claude Code Stop hook, per code.claude.com/docs/en/hooks.md):
#   - stdin: JSON including a "cwd" field (the session's working directory).
#   - Exit 0 = non-blocking. Optional stdout JSON with
#     hookSpecificOutput.systemMessage surfaces a message without stopping
#     or blocking anything.
#   - Never blocks session end, and never errors when cwd is not a git repo
#     (many sessions run outside any repo).

INPUT="$(cat)"

CWD="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("cwd", ""))
except Exception:
    print("")
' 2>/dev/null)"

if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
    exit 0
fi

if ! git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    exit 0
fi

STATUS="$(git -C "$CWD" status --porcelain 2>/dev/null)"

if [ -n "$STATUS" ]; then
    COUNT="$(printf '%s\n' "$STATUS" | grep -c .)"
    CWD="$CWD" COUNT="$COUNT" python3 -c '
import json, os
cwd = os.environ.get("CWD", "")
count = os.environ.get("COUNT", "0")
msg = "Uncommitted changes in " + cwd + ": " + count + " file(s) not committed (git status)."
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "Stop",
        "systemMessage": msg
    }
}))
'
fi

exit 0
