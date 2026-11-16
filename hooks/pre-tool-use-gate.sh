#!/usr/bin/env bash
# pre-tool-use-gate.sh — PreToolUse enforcement hook
# Enforces: GR-S11-2 (sudo gate), GR-NEW-31 (diagnostic source), GR-QS-7-AMENDED (UI source)
# Fail-open: on any parse or script error, exit 0 to allow the tool call.

INPUT="$(cat 2>/dev/null)" || exit 0

TOOL_NAME=$(echo "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_name",""))' 2>/dev/null) || TOOL_NAME=""

deny() {
    # Pass reason via env var to avoid shell quoting hazards
    DENY_REASON="$1" python3 -c "
import json, os
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': os.environ.get('DENY_REASON', 'blocked by hook')
    }
}))
" 2>/dev/null || true
    exit 0
}

# ─── BASH TOOL GATES ─────────────────────────────────────────────────────────
if [ "$TOOL_NAME" = "Bash" ]; then
    CMD=$(echo "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("command",""))' 2>/dev/null) || CMD=""

    # GATE 1 — GR-S11-2: Block automated sudo commands
    # Match sudo as an actual invocation (at line start or after shell separator),
    # not just the word "sudo" appearing inside a quoted string argument.
    # Exception: sudo -n true (the availability check itself)
    if echo "$CMD" | grep -qE '(^|[;&|`])\s*sudo\b' && ! echo "$CMD" | grep -qE 'sudo -n true'; then
        deny "BLOCKED GR-S11-2 (sudo gate): Automated sudo commands are prohibited (sudo_status:1 confirmed this session). Redesign as: (a) user-run command with output saved to scratchpad, or (b) Portainer API call. No further automated sudo attempts this session."
    fi

    # GATE 2 — GR-NEW-31: Diagnostic investigation source gate
    # Triggers on docker exec/logs, log file greps, journalctl
    if echo "$CMD" | grep -qE "(docker (exec|logs)\b|grep.*(-[iElE]+).*(\.log|/logs?/|error|warn|buffer|transcode)|journalctl.*docker|find.*plex.*\.log)"; then
        if [ ! -s /tmp/diagnostic-source ]; then
            deny "BLOCKED GR-NEW-31 (diagnostic source gate): No methodology source set for this investigation. Run first: echo 'source: [URL or document description]' > /tmp/diagnostic-source"
        fi
    fi

    # GATE 3 — GR-QS-18-AMENDED: Named container resource verification gate
    # Block docker exec/logs/start/stop/restart with a specific container name
    # unless that container has been verified via docker ps this session.
    # Exception: docker ps and docker inspect are verification commands themselves.
    if echo "$CMD" | grep -qE "\bdocker\b.+\b(exec|logs|start|stop|restart)\b" && ! echo "$CMD" | grep -qE "\bdocker ps\b|\bdocker inspect\b"; then
        CONTAINER=$(echo "$CMD" | python3 -c "
import re, sys
cmd = sys.stdin.read().strip()
m = re.search(r'docker\s+(?:\S+\s+)*(exec|logs|start|stop|restart)\s+(?:-\S+\s+)*([a-zA-Z][a-zA-Z0-9_.:-]+)', cmd)
print(m.group(2) if m else '')
" 2>/dev/null) || CONTAINER=""

        if [ -n "$CONTAINER" ]; then
            VERIFIED="/tmp/container-verified-${CONTAINER}"
            if [ ! -f "$VERIFIED" ]; then
                deny "BLOCKED GR-QS-18-AMENDED (named resource gate): Container '$CONTAINER' not verified this session. Run 'docker ps --format ...' (manually with sudo), then: touch $VERIFIED"
            fi
        fi
    fi
fi

# ─── BROWSER NAVIGATION GATE ─────────────────────────────────────────────────
# GR-QS-7-AMENDED: UI navigation requires a captured source for non-preauthorised URLs.
# Pre-authorised homelab URLs (from autoMode.environment):
#   Portainer: 100.78.21.71:9443
#   arr stack:  100.78.21.71:18989 / :17878 / :19696
#   Plex:       100.78.21.71:32400 / 192.168.4.127:32400
if echo "$TOOL_NAME" | grep -qE "mcp__.*navigate"; then
    URL=$(echo "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("url",""))' 2>/dev/null) || URL=""

    if ! echo "$URL" | grep -qE "(100\.78\.21\.71:(9443|18989|17878|19696|32400|8080)|192\.168\.4\.127:(32400|18989|17878|19696))"; then
        if [ ! -s /tmp/ui-source-confirmed ]; then
            deny "BLOCKED GR-QS-7-AMENDED (UI source gate): '$URL' is not a pre-authorised homelab URL. A captured source is required before navigating here. Set: echo 'source: [documentation URL]' > /tmp/ui-source-confirmed"
        fi
    fi
fi

exit 0
