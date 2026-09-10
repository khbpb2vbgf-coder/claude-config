#!/usr/bin/env python3
"""
UserPromptSubmit hook: reads STANDING CONSTRAINTS from ~/.claude/CLAUDE.md
and injects them as additionalContext on every turn.

Falls back to the full file content when the section heading is not found,
so the hook never silently injects nothing due to a heading rename or typo.
Never blocks a turn on any error.
"""

import json
import re
import sys
from pathlib import Path


def main():
    raw = sys.stdin.read()
    try:
        json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        sys.exit(0)

    claude_md = Path.home() / ".claude" / "CLAUDE.md"
    if not claude_md.exists():
        sys.exit(0)

    try:
        content = claude_md.read_text(encoding="utf-8")
    except OSError:
        sys.exit(0)

    match = re.search(
        r"## STANDING CONSTRAINTS.*?(?=\n## |\Z)",
        content,
        re.DOTALL,
    )

    if match:
        constraints = match.group(0).strip()
    else:
        # Heading not found — inject full file so nothing is silently lost
        constraints = content.strip()

    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": (
                    "[INJECTED CONSTRAINTS — apply before every response]\n\n"
                    + constraints
                ),
            }
        },
        sys.stdout,
    )
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never block a turn on a hook failure.
        sys.exit(0)
