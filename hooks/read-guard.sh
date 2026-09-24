#!/usr/bin/env bash
# PreToolUse:Read -- deny unbounded reads of large files, route to bulk-reader.
set -u
SHUNT_T0=$(date +%s%N)
SHUNT_HOOK="read_guard"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/common.sh"
. "$DIR/lib/decide.sh"

PAYLOAD=$(timeout 2 cat) || PAYLOAD=""
jq -e . >/dev/null 2>&1 <<<"$PAYLOAD" || { SHUNT_HOOK="read_guard"; shunt_log "unparseable_payload" "none"; exit 0; }

eval "$(jq -r '
  def s: if type=="string" then . else "" end;
  def n: if type=="number" then tostring else "" end;
  if type=="object" then . else {} end
  | (.tool_input |= (if type=="object" then . else {} end))
  | @sh "TOOL_NAME=\(.tool_name|s)
SESSION_ID=\(.session_id|s)
AGENT_TYPE=\(.agent_type|s)
AGENT_ID=\(.agent_id|s)
CWD=\(.cwd|s)
TRANSCRIPT_PATH=\(.transcript_path|s)
FILE_PATH=\(.tool_input.file_path|s)
OFFSET=\(.tool_input.offset|n)
LIMIT=\(.tool_input.limit|n)"' <<<"$PAYLOAD")"

shunt_load_config
COMMAND_STR=""
PATHS_JSON="[]"
EST_TOKENS=0
EST_TOKENS_UNCAPPED=0
DENY_COUNT=0

[ "$TOOL_NAME" = "Read" ] || shunt_allow "not_a_reader_command"
shunt_common_guards || true

# A windowed read is the model saying it already knows what it wants -- and it
# is exactly what we tell it to do after a deny, so it must always be allowed.
# Fast path: a `limit` within the threshold cannot return more, whatever the
# file, so it needs no probe.
[ -n "$LIMIT" ] && [ "$(shunt_int "$LIMIT" 0)" -le "$MIN_LINES" ] && shunt_allow "targeted_read"

case "$FILE_PATH" in
  /*) ABS="$FILE_PATH" ;;
  ~*) ABS="${FILE_PATH/#\~/$HOME}" ;;
  "") shunt_allow "file_missing" ;;
  *)  ABS="${CWD:-$PWD}/$FILE_PATH" ;;
esac

# Never shunt our own logs or state.
case "$ABS" in *"/.haiku-shunt/"*|*"/haiku-shunt/metrics/"*) shunt_allow "path_exempt" ;; esac

shunt_probe "$ABS" || shunt_allow "$F_REASON"

# Any other window is judged by what it RETURNS, like `tail -n +K` in the Bash
# hook: an offset alone reads up to TRUNC_LINES lines, so Read(offset=1) is a
# full read by another name, while a large limit near the end of the file may
# return only a few lines. offset is 1-based.
if [ -n "$OFFSET" ] || [ -n "$LIMIT" ]; then
  off=$(shunt_int "$OFFSET" 1); [ "$off" -lt 1 ] && off=1
  eff=$(shunt_int "$LIMIT" "$TRUNC_LINES")
  rest=$(( F_LINES - off + 1 )); [ "$rest" -lt 0 ] && rest=0
  [ "$rest" -lt "$eff" ] && eff="$rest"
  win_bytes=0; [ "$F_LINES" -gt 0 ] && win_bytes=$(( F_BYTES * eff / F_LINES ))
  PATHS_JSON=$(jq -cn --arg p "$FILE_PATH" --arg a "$ABS" --argjson l "$F_LINES" \
    --argjson e "$eff" --argjson b "$F_BYTES" --argjson o "$off" \
    '[{path:$p, abs:$a, exists:true, lines:$l, effective_lines:$e, bytes:$b, offset:$o}]')
  [ "$eff" -le "$MIN_LINES" ] && shunt_allow "targeted_read"
  # Same byte floor as a full read: a small file is never worth a subagent.
  [ "$F_BYTES" -gt "$MIN_BYTES" ] || shunt_allow "under_byte_floor"
  EST_TOKENS=$(shunt_est_tokens "$win_bytes" "$eff")
  EST_TOKENS_UNCAPPED="$EST_TOKENS"
  shunt_deny "window_over_threshold" "Read of $FILE_PATH" \
    "a window of $eff lines from line $off, threshold $MIN_LINES" "$EST_TOKENS" "$ABS"
fi

EST_TOKENS_UNCAPPED=$(shunt_est_tokens "$F_BYTES" "$F_LINES")
EST_TOKENS=$(shunt_capped_tokens "$ABS" "$F_BYTES" "$F_LINES")
PATHS_JSON=$(jq -cn --arg p "$FILE_PATH" --arg a "$ABS" \
  --argjson l "$F_LINES" --argjson b "$F_BYTES" --argjson t "$EST_TOKENS" \
  '[{path:$p, abs:$a, exists:true, lines:$l, bytes:$b, est_tokens:$t}]')

# A file can be huge without having many lines (minified bundles, one-line
# JSON). Line count alone misses those entirely.
if [ "$F_BYTES" -gt "$MAX_BYTES" ]; then
  shunt_deny "over_threshold" "Read of $FILE_PATH" "$F_BYTES bytes" "$EST_TOKENS" "$ABS"
fi

# Both gates must trip. The byte floor stops a 400-line, 3 KB config file from
# round-tripping through a subagent for a guaranteed net loss.
if [ "$F_LINES" -gt "$MIN_LINES" ] && [ "$F_BYTES" -gt "$MIN_BYTES" ]; then
  shunt_deny "over_threshold" "Read of $FILE_PATH" \
    "$F_LINES lines, threshold $MIN_LINES" "$EST_TOKENS" "$ABS"
fi

EST_TOKENS=0
[ "$F_LINES" -gt "$MIN_LINES" ] && shunt_allow "under_byte_floor"
shunt_allow "under_threshold"
