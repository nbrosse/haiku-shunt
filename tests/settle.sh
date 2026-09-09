#!/usr/bin/env bash
# SubagentStop fires while the worker's last message is still being flushed.
# Observed live: the hook read the transcript ~100ms before the final text
# block landed and recorded output_tokens=204 for a message that cost 1,216.
# These cases pin the wait that fixes it.
set -uo pipefail
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILED=0
chk(){ if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: got=$2 want=$3"; FAILED=1; fi; }

mk_payload() { # $1 agent transcript path
  jq -cn --arg tp "$T/parent.jsonl" --arg atp "$1" \
    '{session_id:"s1", agent_id:"abc123", agent_type:"haiku-shunt:bulk-reader",
      transcript_path:$tp, agent_transcript_path:$atp}'
}
run_hook() { # $1 payload -> last delegation record
  local log="$T/log"; rm -rf "$log"; mkdir -p "$log"
  printf '%s' "$1" | env SHUNT_LOG_DIR="$log" bash "$P/hooks/subagent-stop.sh" >/dev/null 2>&1
  tail -1 "$log"/events-*.jsonl 2>/dev/null
}

ROW_A='{"type":"assistant","message":{"id":"msg_1","model":"claude-haiku-4-5-20251001","content":[{"type":"tool_use"}],"usage":{"input_tokens":50,"output_tokens":200,"cache_creation_input_tokens":9000,"cache_read_input_tokens":0}}}'
# The final message, arriving in two blocks: a 1-token thinking block, then the
# real text. Reading between them is exactly the bug.
ROW_B1='{"type":"assistant","message":{"id":"msg_2","model":"claude-haiku-4-5-20251001","content":[{"type":"thinking"}],"usage":{"input_tokens":10,"output_tokens":1,"cache_creation_input_tokens":100,"cache_read_input_tokens":9000}}}'
ROW_B2='{"type":"assistant","message":{"id":"msg_2","model":"claude-haiku-4-5-20251001","content":[{"type":"text"}],"usage":{"input_tokens":10,"output_tokens":1013,"cache_creation_input_tokens":100,"cache_read_input_tokens":9000}}}'

# 1. A transcript that is still growing: the last block lands 400ms in.
A="$T/subagents/agent-abc123.jsonl"; mkdir -p "$(dirname "$A")"
printf '%s\n%s\n' "$ROW_A" "$ROW_B1" > "$A"
( sleep 0.4; printf '%s\n' "$ROW_B2" >> "$A" ) &
WRITER=$!
REC=$(run_hook "$(mk_payload "$A")")
wait $WRITER
chk "waits for the late block: output"  "$(jq -r '.usage.output_tokens' <<<"$REC")" 1213
chk "waits for the late block: summary" "$(jq -r '.summary_tokens'      <<<"$REC")" 1013
chk "records that it settled"           "$(jq -r '.transcript_settled'  <<<"$REC")" true

# 1b. THE regression: a 700ms pause between the thinking block and the text
# block. A "file stopped growing" check samples inside that pause and settles
# early, losing the 1,013-token block.
printf '%s\n%s\n' "$ROW_A" "$ROW_B1" > "$A"
( sleep 0.7; printf '%s\n' "$ROW_B2" >> "$A" ) &
WRITER=$!
REC=$(run_hook "$(mk_payload "$A")")
wait $WRITER
chk "a pause mid-message is not completion" "$(jq -r '.usage.output_tokens' <<<"$REC")" 1213

# 2. An already-complete transcript must not be delayed into next week.
printf '%s\n%s\n%s\n' "$ROW_A" "$ROW_B1" "$ROW_B2" > "$A"
t0=$(date +%s%N)
REC=$(run_hook "$(mk_payload "$A")")
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
chk "settled file still measured" "$(jq -r '.usage.output_tokens' <<<"$REC")" 1213
if [ "$ms" -lt 3000 ]; then echo "ok settled file is not slow (${ms}ms)"
else echo "FAIL settled file is not slow: ${ms}ms"; FAILED=1; fi

# 3. Fail-open: a missing transcript must still emit a record, not hang or die.
REC=$(run_hook "$(mk_payload "$T/subagents/agent-nope.jsonl")")
chk "missing transcript still records" "$(jq -r '.event' <<<"$REC")" "delegation"
chk "and says the usage is unavailable" "$(jq -r '.usage_source' <<<"$REC")" "unavailable"

# 4. A non-worker subagent is not our business.
REC=$(run_hook "$(jq -cn --arg tp "$T/parent.jsonl" --arg atp "$A" \
  '{session_id:"s1", agent_id:"x", agent_type:"Explore",
    transcript_path:$tp, agent_transcript_path:$atp}')")
chk "non-worker agent writes nothing" "${REC:-<none>}" "<none>"

exit $FAILED
