#!/usr/bin/env bash
# post-tool-batch-check.sh — PostToolBatch enforcement hook
# Enforces: GR-NEW-33 (pre-flight declaration must appear before diagnostic tool calls)
# Reads the transcript to verify visible "Pre-flight:" text appeared in Claude's
# response before any diagnostic Bash commands in this batch.
# Fail-open: exits 0 (allow) on any parse error or if transcript unreadable.

INPUT="$(cat 2>/dev/null)" || exit 0

TRANSCRIPT=$(echo "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("transcript_path",""))' 2>/dev/null) || TRANSCRIPT=""

[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

python3 - "$TRANSCRIPT" << 'PYEOF'
import json, re, sys

transcript_path = sys.argv[1]

try:
    with open(transcript_path, 'r') as f:
        lines = f.readlines()
except Exception:
    sys.exit(0)

# Parse all JSONL entries
messages = []
for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        messages.append(json.loads(line))
    except Exception:
        continue

# Find the most recent assistant message
last_assistant = None
for msg in reversed(messages):
    # Claude Code transcripts use 'type' field or 'role' field
    if msg.get('type') == 'assistant' or msg.get('role') == 'assistant':
        last_assistant = msg
        break

if last_assistant is None:
    sys.exit(0)

# Extract text and tool_use blocks from the assistant message
content = last_assistant.get('content', [])
if isinstance(content, str):
    response_text = content
    tool_uses = []
elif isinstance(content, list):
    response_text = ' '.join(c.get('text', '') for c in content if isinstance(c, dict) and c.get('type') == 'text')
    tool_uses = [c for c in content if isinstance(c, dict) and c.get('type') == 'tool_use']
else:
    sys.exit(0)

# Check if any diagnostic Bash commands were in this batch
DIAGNOSTIC_RE = re.compile(
    r'docker\s+(exec|logs)\b'
    r'|grep.*(-[iElE]+).*(\.log|/logs?/|error|warn|buffer|transcode)'
    r'|journalctl.*docker'
    r'|find.*plex.*\.log',
    re.IGNORECASE
)

has_diagnostic = False
for tu in tool_uses:
    if tu.get('name') == 'Bash':
        cmd = tu.get('input', {}).get('command', '')
        if DIAGNOSTIC_RE.search(cmd):
            has_diagnostic = True
            break

if not has_diagnostic:
    sys.exit(0)

# If diagnostic commands present, require "Pre-flight:" in response text
PREFLIGHT_RE = re.compile(r'Pre-flight\s*:', re.IGNORECASE)
if not PREFLIGHT_RE.search(response_text):
    result = {
        'hookSpecificOutput': {
            'hookEventName': 'PostToolBatch',
            'decision': 'block',
            'reason': (
                'BLOCKED GR-NEW-33 (pre-flight declaration): Diagnostic tool calls '
                'were issued without a "Pre-flight: diagnostic source confirmed — [source]" '
                'declaration in the response text. State the methodology source before '
                'issuing diagnostic commands, then re-issue them.'
            )
        }
    }
    print(json.dumps(result))

sys.exit(0)
PYEOF
