#!/usr/bin/env bash
# SubagentStop -- record what a worker actually cost, straight from its own
# transcript. This is the measured half of the cost model; everything the
# report calls "measured" comes from here.
set -u
SHUNT_T0=$(date +%s%N)
SHUNT_HOOK="subagent_stop"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/common.sh"

PAYLOAD=$(timeout 2 cat) || PAYLOAD=""
jq -e . >/dev/null 2>&1 <<<"$PAYLOAD" || exit 0
shunt_load_config

# Same normalization as the guards: valid JSON that is not an object, or fields
# that are not strings, must read as empty rather than crash the hook.
eval "$(jq -r '
  def s: if type=="string" then . else "" end;
  if type=="object" then . else {} end
  | @sh "SESSION_ID=\(.session_id|s)
AGENT_ID=\(.agent_id|s)
AGENT_TYPE=\(.agent_type|s)
TRANSCRIPT_PATH=\(.transcript_path|s)
AGENT_TP=\(.agent_transcript_path|s)"' <<<"$PAYLOAD")" || exit 0

AGENT_BASE="${AGENT_TYPE##*:}"   # "haiku-shunt:bulk-reader" -> "bulk-reader"
case " $WORKER_AGENTS " in *" $AGENT_BASE "*) ;; *) exit 0 ;; esac

# Prefer the path handed to us; otherwise derive it from the parent transcript.
if [ -z "$AGENT_TP" ] || [ ! -f "$AGENT_TP" ]; then
  base="${TRANSCRIPT_PATH%.jsonl}"
  AGENT_TP="$base/subagents/agent-${AGENT_ID}.jsonl"
fi

# The worker's LAST message is still being flushed when SubagentStop fires.
# Measured live: the hook read the transcript ~100ms before the final text
# block landed, recording output_tokens=204 for a message that really cost
# 1,216 - a 6x undercount of the only figure this plugin calls MEASURED.
# Wait for the file to stop growing before reading it. The subagent has already
# finished, so this delay is not in anyone's critical path.
# "The file stopped growing" is too weak a signal: sampling during a pause
# between two blocks of the SAME message reads as settled and loses the block
# that carries the real output count. Wait for the structural marker instead --
# a worker's final message ends on a text block, because a summary is the one
# thing it must return. Quiet time is only the fallback for a transcript that
# never gets one (an interrupted worker), and it fails open either way.
shunt_settle() { # $1 path -> 0 once the final message has landed
  local f="$1" prev="" cur i quiet=0
  for i in $(seq 1 30); do            # 30 * 0.1s = 3s ceiling; hook timeout 15
    tail -1 "$f" 2>/dev/null | jq -e '.message.content[0].type == "text"' \
      >/dev/null 2>&1 && return 0
    cur=$(stat -Lc%s "$f" 2>/dev/null) || return 1
    if [ "$cur" = "$prev" ]; then quiet=$((quiet + 1)); else quiet=0; fi
    [ "$quiet" -ge 8 ] && return 1    # 800ms silent and still no final message
    prev="$cur"
    sleep 0.1
  done
  return 1
}

USAGE="null"; META="null"; SETTLED=false
if [ -f "$AGENT_TP" ]; then
  shunt_settle "$AGENT_TP" && SETTLED=true
  USAGE=$(jq -s -f "$DIR/lib/usage.jq" "$AGENT_TP" 2>/dev/null) || USAGE="null"
  m="${AGENT_TP%.jsonl}.meta.json"
  [ -f "$m" ] && META=$(jq -c '{tool_use_id:.toolUseId, spawn_depth:.spawnDepth, description:.description}' "$m" 2>/dev/null)
fi
[ -z "$USAGE" ] && USAGE="null"
[ -z "$META" ]  && META="null"

shunt_append "$(jq -cn \
  --arg v "$SHUNT_VERSION" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
  --arg sid "$SESSION_ID" --arg aid "$AGENT_ID" --arg at "$AGENT_TYPE" \
  --arg ab "$AGENT_BASE" \
  --arg tp "$TRANSCRIPT_PATH" --arg wtp "$AGENT_TP" \
  --argjson usage "$USAGE" --argjson meta "$META" --argjson settled "$SETTLED" \
  '{v:1, ts:$ts, event:"delegation", plugin_version:$v, phase:"stop",
    session_id:$sid, worker_agent_id:$aid, worker_agent_type:$at,
    worker_agent_base:$ab,
    transcript_path:$tp, worker_transcript_path:$wtp,
    tool_use_id:($meta.tool_use_id // null), spawn_depth:($meta.spawn_depth // null),
    usage:$usage, transcript_settled:$settled,
    summary_tokens:(if $usage == null then null else ($usage.final_output_tokens // null) end),
    usage_source:(if $usage == null then "unavailable" else "subagent_transcript" end),
    status:"ok"}' 2>/dev/null)"
exit 0
