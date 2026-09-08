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

eval "$(jq -r '@sh "SESSION_ID=\(.session_id // "")
AGENT_ID=\(.agent_id // "")
AGENT_TYPE=\(.agent_type // "")
TRANSCRIPT_PATH=\(.transcript_path // "")
AGENT_TP=\(.agent_transcript_path // "")"' <<<"$PAYLOAD")"

AGENT_BASE="${AGENT_TYPE##*:}"   # "haiku-shunt:bulk-reader" -> "bulk-reader"
case " $WORKER_AGENTS " in *" $AGENT_BASE "*) ;; *) exit 0 ;; esac

# Prefer the path handed to us; otherwise derive it from the parent transcript.
if [ -z "$AGENT_TP" ] || [ ! -f "$AGENT_TP" ]; then
  base="${TRANSCRIPT_PATH%.jsonl}"
  AGENT_TP="$base/subagents/agent-${AGENT_ID}.jsonl"
fi

USAGE="null"; META="null"
if [ -f "$AGENT_TP" ]; then
  USAGE=$(jq -s -f "$DIR/lib/usage.jq" "$AGENT_TP" 2>/dev/null) || USAGE="null"
  m="${AGENT_TP%.jsonl}.meta.json"
  [ -f "$m" ] && META=$(jq -c '{tool_use_id:.toolUseId, spawn_depth:.spawnDepth, description:.description}' "$m" 2>/dev/null)
fi
[ -z "$USAGE" ] && USAGE="null"
[ -z "$META" ]  && META="null"

shunt_append "$(jq -cn \
  --arg v "$SHUNT_VERSION" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
  --arg sid "$SESSION_ID" --arg aid "$AGENT_ID" --arg at "$AGENT_TYPE" \
  --arg tp "$TRANSCRIPT_PATH" --arg wtp "$AGENT_TP" \
  --argjson usage "$USAGE" --argjson meta "$META" \
  '{v:1, ts:$ts, event:"delegation", plugin_version:$v, phase:"stop",
    session_id:$sid, worker_agent_id:$aid, worker_agent_type:$at,
    transcript_path:$tp, worker_transcript_path:$wtp,
    tool_use_id:($meta.tool_use_id // null), spawn_depth:($meta.spawn_depth // null),
    usage:$usage,
    usage_source:(if $usage == null then "unavailable" else "subagent_transcript" end),
    status:"ok"}' 2>/dev/null)"
exit 0
