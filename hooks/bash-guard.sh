#!/usr/bin/env bash
# PreToolUse:Bash -- catch cat/head/tail/less/more dumps that bypass the Read
# hook. Fast path first: most Bash calls mention no reader at all and must not
# pay for a Python start-up.
set -u
SHUNT_T0=$(date +%s%N)
SHUNT_HOOK="bash_guard"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/common.sh"
. "$DIR/lib/decide.sh"

PAYLOAD=$(timeout 2 cat) || PAYLOAD=""
jq -e . >/dev/null 2>&1 <<<"$PAYLOAD" || { shunt_log "unparseable_payload" "none"; exit 0; }

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
COMMAND_STR=\(.tool_input.command|s)"' <<<"$PAYLOAD")"

shunt_load_config
PATHS_JSON="[]"; EST_TOKENS=0; EST_TOKENS_UNCAPPED=0; DENY_COUNT=0

[ "$TOOL_NAME" = "Bash" ] || shunt_allow "not_a_reader_command"
[ -n "$COMMAND_STR" ]     || shunt_allow "not_a_reader_command"

# Fast path: no reader command name anywhere => nothing to do. This is the
# common case (git, npm, ls, pytest) and it must stay cheap.
READER_RE=$(printf '%s' "$READER_CMDS" | tr ' ' '|')
grep -qE "(^|[^[:alnum:]_-])($READER_RE)([^[:alnum:]_-]|$)" <<<"$COMMAND_STR" \
  || shunt_allow "not_a_reader_command"

shunt_common_guards || true

PARSE=$(printf '%s' "$COMMAND_STR" | timeout 3 python3 "$DIR/lib/bashparse.py" "${CWD:-$PWD}" 2>/dev/null) \
  || shunt_allow "internal_error"
jq -e . >/dev/null 2>&1 <<<"$PARSE" || shunt_allow "internal_error"

VERDICT=$(jq -r '.verdict' <<<"$PARSE")
REASON=$(jq -r '.reason'  <<<"$PARSE")
READER=$(jq -r '.reader // ""' <<<"$PARSE")
BOUND=$(jq -r '.bound_lines // ""' <<<"$PARSE")
FROM_LINE=$(jq -r '.from_line // ""' <<<"$PARSE")
[ "$VERDICT" = "check" ] || shunt_allow "$REASON"

mapfile -t FILES < <(jq -r '.files[]' <<<"$PARSE")
# A command with hundreds of operands is not a read we can meaningfully
# summarise, and passing them all to jq blows past ARG_MAX. Probe a bounded
# prefix: if none of the first 16 trips the threshold, neither does the tail
# in any way worth a subagent round-trip.
MAX_OPERANDS=16
TOTAL_OPERANDS=${#FILES[@]}
[ "$TOTAL_OPERANDS" -gt "$MAX_OPERANDS" ] && FILES=("${FILES[@]:0:$MAX_OPERANDS}")

TOTAL_LINES=0; TOTAL_BYTES=0; TRIP=0; PATHS=(); FIRST_ABS=""; DETAIL=""
PROBED=0; LAST_FAIL=""
for f in "${FILES[@]}"; do
  case "$f" in *"/.haiku-shunt/"*|*"/haiku-shunt/metrics/"*) shunt_allow "path_exempt" ;; esac
  if ! shunt_probe "$f"; then
    PATHS+=("$(jq -cn --arg a "$f" --arg r "$F_REASON" '{abs:$a, exists:false, reason:$r}')")
    LAST_FAIL="$F_REASON"
    continue
  fi

  # How many lines does this command actually put on stdout?
  eff="$F_LINES"
  if [ -n "$FROM_LINE" ] && [ "$FROM_LINE" != "null" ]; then
    eff=$(( F_LINES - FROM_LINE + 1 )); [ "$eff" -lt 0 ] && eff=0
  elif [ -n "$BOUND" ] && [ "$BOUND" != "null" ]; then
    [ "$BOUND" -lt "$eff" ] && eff="$BOUND"
  fi

  PROBED=$((PROBED + 1))
  [ -z "$FIRST_ABS" ] && FIRST_ABS="$f"
  PATHS+=("$(jq -cn --arg a "$f" --argjson l "$F_LINES" --argjson e "$eff" --argjson b "$F_BYTES" \
              '{abs:$a, exists:true, lines:$l, effective_lines:$e, bytes:$b}')")

  if [ "$eff" -gt "$MIN_LINES" ] && [ "$F_BYTES" -gt "$MIN_BYTES" ]; then
    TRIP=1; DETAIL="$eff lines, threshold $MIN_LINES"
  elif [ "$F_BYTES" -gt "$MAX_BYTES" ] && [ "$eff" -eq "$F_LINES" ]; then
    TRIP=1; DETAIL="$F_BYTES bytes"
  fi
  TOTAL_LINES=$((TOTAL_LINES + eff))
  TOTAL_BYTES=$((TOTAL_BYTES + F_BYTES))
done

PATHS_JSON=$(printf '%s\n' "${PATHS[@]:0:8}" | jq -cs 'map(select(. != null))' 2>/dev/null) || PATHS_JSON="[]"
EST_TOKENS_UNCAPPED=$(shunt_est_tokens "$TOTAL_BYTES" "$TOTAL_LINES")
EST_TOKENS="$EST_TOKENS_UNCAPPED"   # no Read truncation applies to a shell dump

if [ "$TRIP" = "1" ]; then
  what="\`$READER\` of ${#FILES[@]} file(s)"
  [ "${#FILES[@]}" = "1" ] && what="\`$READER $(basename "$FIRST_ABS")\`"
  shunt_deny "over_threshold" "$what" "$DETAIL" "$EST_TOKENS" "$FIRST_ABS"
fi

EST_TOKENS=0
[ "$PROBED" -eq 0 ] && [ -n "$LAST_FAIL" ] && shunt_allow "$LAST_FAIL"
shunt_allow "under_threshold"
