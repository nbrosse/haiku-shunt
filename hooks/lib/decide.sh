#!/usr/bin/env bash
# Decision emitter: the deny message is the highest-leverage string in this
# repo. It is the only thing standing between a blocked read and a model that
# does not know how to proceed, so it names every escape hatch explicitly.
set -u

shunt_deny_reason() { # $1 what, $2 detail, $3 est tokens
  cat <<EOF
$1 was blocked to keep it out of this session's context ($2, ~$3 tokens — context is re-sent on every following turn).

Pick one:
1. A question about the whole file, or an overview: Task(subagent_type="bulk-reader", prompt="<the specific question> about <paths>"). It reads the files in its own context on Haiku and returns a compact summary with exact line anchors. Do not page through the whole file in windows instead: that puts all of it in this context anyway.
2. You already know where to look: re-issue Read with offset and a limit of at most ${MIN_LINES} lines. Windows that size are always allowed, and you need one anyway before editing. A larger limit is blocked like a full read.
3. Looking for a symbol or string: use Grep first.

Line numbers in a summary are for navigation. Before editing, confirm the range with a windowed Read.
EOF
}

# $1 reason_code, $2 what, $3 detail, $4 est_tokens, $5 primary abs path
shunt_deny() {
  local rc="$1" what="$2" detail="$3" tokens="$4" path="$5" reason

  DENY_COUNT=$(shunt_deny_count "$path")
  if [ "$DENY_COUNT" -gt "$MAX_DENIES" ]; then
    # Escape valve: the model has asked three times. Whatever it is doing, it
    # is not going to be talked out of it, and a loop is worse than a big read.
    shunt_allow "deny_cap_reached"
  fi

  reason=$(shunt_deny_reason "$what" "$detail" "$tokens")

  if [ "$MODE" = "warn" ]; then
    jq -cn --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:$r}}'
    shunt_log "$rc" "none"
    exit 0
  fi

  jq -cn --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",
                          permissionDecision:"deny",
                          permissionDecisionReason:$r}}'
  shunt_log "$rc" "deny"
  exit 0
}

# Guards that apply to both hooks. Returns 0 if the caller should stop.
shunt_common_guards() {
  [ "${SHUNT_DISABLE:-0}" = "1" ] && shunt_allow "disabled"

  # Guard A: never shunt our own workers -- that is the deadlock.
  # Key off agent_type alone: agent_id is omitted on the main thread, and is
  # also absent for a main thread started with --agent, so it cannot
  # discriminate. Absent, null and empty are all treated as "main thread".
  if [ -n "${AGENT_TYPE:-}" ]; then
    # Plugin agents are namespaced: "haiku-shunt:bulk-reader". Verified live -
    # matching the bare name here denied our own worker's reads and cost it
    # three extra turns to work around.
    local base="${AGENT_TYPE##*:}"
    case " $WORKER_AGENTS " in *" $base "*) shunt_allow "self_agent_bypass" ;; esac
    [ "$SHUNT_OTHER" = "0" ] && shunt_allow "other_agent_exempt"
  fi
  return 1
}
