#!/usr/bin/env bash
# Stop hook for "interactive-p" mode.
#   - If CLAUDE_SNAP_ENVELOPE is unset, do nothing (normal interactive session).
#   - Otherwise: merge Stop stdin + statusline sidecar into a draft envelope,
#     write it atomically to CLAUDE_SNAP_ENVELOPE, then SIGTERM the parent claude
#     TUI process so it exits. The wrapper enriches with transcript-derived
#     fields (usage/stop_reason/num_turns) AFTER claude exits, when the
#     transcript JSONL is fully flushed.
set -euo pipefail
input=$(cat)

DEBUG_LOG="${CLAUDE_SNAP_DEBUG_LOG:-}"
log() { [ -n "$DEBUG_LOG" ] && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$DEBUG_LOG" || true; }

if [ -z "${CLAUDE_SNAP_ENVELOPE:-}" ]; then
  log "no envelope env, no-op"
  exit 0
fi

# Statusline ticks are debounced 300ms behind the "new assistant message"
# trigger that ALSO fires this Stop hook. Without this wait, the hook would
# read the previous (often session-start) statusline payload with empty
# cost/context. Snapshot the sidecar's mtime once, then wait for it to
# advance. Using > (strict) rather than comparing against a wall-clock start
# avoids the same-integer-second race where a sidecar written in the same
# second as the hook start would falsely match on the first check.
sidecar='{}'
if [ -n "${CLAUDE_SNAP_SIDECAR:-}" ]; then
  sidecar_mtime() {
    stat -f %m "$CLAUDE_SNAP_SIDECAR" 2>/dev/null \
      || stat -c %Y "$CLAUDE_SNAP_SIDECAR" 2>/dev/null \
      || echo 0
  }
  prev_mtime=$(sidecar_mtime)
  # Cap at 10 × 0.15s = 1.5s. statusline debounce is 300ms, so this gives
  # multiple chances to land plus headroom for slow disks.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -f "$CLAUDE_SNAP_SIDECAR" ] && [ "$(sidecar_mtime)" -gt "$prev_mtime" ]; then
      break
    fi
    sleep 0.15
  done
  if [ -f "$CLAUDE_SNAP_SIDECAR" ]; then
    sidecar=$(cat "$CLAUDE_SNAP_SIDECAR")
  else
    log "sidecar never appeared, emitting envelope without statusline fields"
  fi
fi

envelope=$(jq -n \
  --argjson stop "$input" \
  --argjson side "$sidecar" '
  {
    type: "result",
    subtype: "success",
    session_id: $stop.session_id,
    transcript_path: $stop.transcript_path,
    cwd: $stop.cwd,
    permission_mode: $stop.permission_mode,
    result: $stop.last_assistant_message,
    background_tasks: $stop.background_tasks,
    session_crons: $stop.session_crons,
    statusline: $side
  }
')

tmp="${CLAUDE_SNAP_ENVELOPE}.tmp.$$"
printf '%s\n' "$envelope" > "$tmp"
mv "$tmp" "$CLAUDE_SNAP_ENVELOPE"
log "draft envelope written, killing ppid=$PPID"

# $PPID is the claude TUI process, verified by ancestor walk during PoC.
# Assumes claude execs the hook command as a direct child (current behavior).
# If a future Claude Code version wraps hook invocations in a shell, $PPID
# would point at that shell and the TUI wouldn't exit cleanly.
kill -TERM "$PPID" >/dev/null 2>&1 || log "kill failed for ppid=$PPID"
exit 0
