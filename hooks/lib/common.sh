#!/usr/bin/env bash
# haiku-shunt — shared hook runtime.
#
# INVARIANT: this code must never break a session. Every path ends in `exit 0`.
# We deliberately do not use `set -e`: a failed probe must fall through to the
# allow path, not abort the hook and leave the tool call blocked.
set -u

SHUNT_VERSION="0.1.0"
SHUNT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHUNT_ROOT="$(cd "$SHUNT_LIB_DIR/../.." && pwd)"

# The allow path emits NOTHING. Emitting {"permissionDecision":"allow"} would
# override the user's own permission rules, which is not ours to do.
shunt_allow() {  # $1 reason_code
  shunt_log "${1:-unspecified}" "none"
  exit 0
}

shunt_fail_open() { # last-resort: something went wrong inside the hook
  shunt_log "internal_error" "none" 2>/dev/null || true
  exit 0
}
trap shunt_fail_open ERR

# ---------------------------------------------------------------- config ----
shunt_int() { # $1 value, $2 fallback -- non-numeric input falls back silently
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

# One jq spawn, not one per key: this runs on every single Read and Bash call.
shunt_load_config() {
  local cfg
  cfg=$(jq -r '@sh "CFG_MIN_LINES=\(.thresholds.min_lines)
CFG_MIN_BYTES=\(.thresholds.min_bytes)
CFG_MAX_BYTES=\(.thresholds.max_bytes)
CFG_TRUNC=\(.thresholds.read_truncation_lines)
CFG_MAX_DENIES=\(.thresholds.max_denies_per_path)
CFG_DENY_TTL=\(.thresholds.deny_ttl_seconds)
CFG_RETENTION=\(.logging.retention_days // 30)
CFG_MODE=\(.policy.mode)
CFG_WORKERS=\(.policy.worker_agents|join(" "))
CFG_READERS=\(.policy.reader_commands|join(" "))
CFG_EXT=\(.policy.exempt_extensions|join(" "))"' "$SHUNT_ROOT/config/defaults.json" 2>/dev/null) || cfg=""
  CFG_MIN_LINES=350; CFG_MIN_BYTES=8000; CFG_MAX_BYTES=200000; CFG_TRUNC=2000
  CFG_MAX_DENIES=2; CFG_DENY_TTL=1800; CFG_RETENTION=30; CFG_MODE=deny
  CFG_WORKERS="bulk-reader code-writer"; CFG_READERS="cat less more bat head tail"; CFG_EXT=""
  [ -n "$cfg" ] && eval "$cfg"

  MIN_LINES=$(shunt_int "${SHUNT_MIN_LINES:-}" "$CFG_MIN_LINES")
  MIN_BYTES=$(shunt_int "${SHUNT_MIN_BYTES:-}" "$CFG_MIN_BYTES")
  MAX_BYTES=$(shunt_int "${SHUNT_MAX_BYTES:-}" "$CFG_MAX_BYTES")
  TRUNC_LINES=$(shunt_int "${SHUNT_READ_TRUNCATION_LINES:-}" "$CFG_TRUNC")
  MAX_DENIES=$(shunt_int "${SHUNT_MAX_DENIES_PER_PATH:-}" "$CFG_MAX_DENIES")
  DENY_TTL=$(shunt_int "${SHUNT_DENY_TTL:-}" "$CFG_DENY_TTL")
  RETENTION_DAYS=$(shunt_int "${SHUNT_LOG_RETENTION_DAYS:-}" "$CFG_RETENTION")
  MODE="${SHUNT_MODE:-$CFG_MODE}"
  SHUNT_OTHER="${SHUNT_SHUNT_OTHER_AGENTS:-1}"
  WORKER_AGENTS="$CFG_WORKERS"
  READER_CMDS="$CFG_READERS"
  EXEMPT_EXT="$CFG_EXT"
}

# ------------------------------------------------------------- log target ----
shunt_log_dir() {
  local d
  for d in "${SHUNT_LOG_DIR:-}" \
           "${HAIKU_SHUNT_PLUGIN_DATA:-}/metrics" \
           "${CLAUDE_PLUGIN_DATA:-}/metrics" \
           "${CLAUDE_PROJECT_DIR:-}/.haiku-shunt/metrics" \
           "${XDG_STATE_HOME:-$HOME/.local/state}/haiku-shunt/metrics"; do
    case "$d" in ''|'/metrics') continue ;; esac
    if mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; then
      chmod 700 "$d" 2>/dev/null || true
      printf '%s' "$d"; return 0
    fi
  done
  return 1
}

# One record == one printf == one write(2) of <=4000 bytes. O_APPEND makes a
# single write atomic on a local filesystem, so concurrent hooks cannot
# interleave. SHUNT_LOG_LOCK=1 adds flock for network filesystems, where
# O_APPEND atomicity is not guaranteed.
shunt_append() { # $1 compact json line
  local dir line f
  dir=$(shunt_log_dir) || return 0
  line="$1"
  # A record builder that hit E2BIG or a jq error returns nothing; never write
  # a blank line into a JSONL file that other tools have to parse.
  if [ -z "$line" ] || ! jq -e . >/dev/null 2>&1 <<<"$line"; then
    line=$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" --arg h "${SHUNT_HOOK:-}" \
      '{v:1, ts:$ts, event:"emit_error", hook:$h, reason:"record_build_failed"}' 2>/dev/null) \
      || line='{"v":1,"event":"emit_error","reason":"record_build_failed"}'
  fi
  if [ "${#line}" -gt 3900 ]; then
    line=$(printf '%s' "$line" | jq -c '.command = ((.command // "")[0:200]) | .paths = ((.paths // [])[0:4]) | .truncated = true' 2>/dev/null) || return 0
  fi
  [ "${#line}" -gt 4000 ] && line='{"v":1,"event":"emit_error","reason":"record_too_large"}'
  f="$dir/events-$(date -u +%Y-%m-%d).jsonl"
  # First record of the day: prune old logs and deny state, so the log (which
  # holds commands and paths) does not grow forever. 0 keeps everything.
  [ -e "$f" ] || shunt_prune "$dir"
  if [ "${SHUNT_LOG_LOCK:-0}" = "1" ]; then
    ( flock -x 9; printf '%s\n' "$line" >&9 ) 9>>"$f" 2>/dev/null || true
  else
    printf '%s\n' "$line" >> "$f" 2>/dev/null || true
  fi
  chmod 600 "$f" 2>/dev/null || true
}

shunt_prune() { # $1 log dir
  local days="${RETENTION_DAYS:-30}"
  [ "$days" -gt 0 ] 2>/dev/null || return 0
  find "$1" -maxdepth 1 -name 'events-*.jsonl' -mtime +"$((days - 1))" -delete 2>/dev/null
  find "$1/state" -maxdepth 1 -type f -mtime +"$((days - 1))" -delete 2>/dev/null
  return 0
}

shunt_log() { # $1 reason_code, $2 decision
  local elapsed
  elapsed=$(( ($(date +%s%N) - SHUNT_T0) / 1000000 ))
  shunt_append "$(jq -cn \
    --arg v "$SHUNT_VERSION" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
    --arg hook "$SHUNT_HOOK" --arg tool "${TOOL_NAME:-}" \
    --arg sid "${SESSION_ID:-}" --arg at "${AGENT_TYPE:-}" --arg aid "${AGENT_ID:-}" \
    --arg cwd "${CWD:-}" --arg tp "${TRANSCRIPT_PATH:-}" \
    --arg dec "$2" --arg rc "$1" --arg cmd "${COMMAND_STR:0:2000}" \
    --argjson paths "${PATHS_JSON:-[]}" \
    --argjson tok "${EST_TOKENS:-0}" --argjson toku "${EST_TOKENS_UNCAPPED:-0}" \
    --argjson thl "${MIN_LINES:-0}" --argjson thb "${MIN_BYTES:-0}" \
    --argjson dc "${DENY_COUNT:-0}" --argjson ms "$elapsed" --argjson pid "$$" \
    '{v:1, ts:$ts, event:"hook_decision", plugin_version:$v, hook:$hook,
      tool_name:$tool, session_id:$sid,
      agent_type:(if $at=="" then null else $at end),
      agent_id:(if $aid=="" then null else $aid end),
      cwd:$cwd, transcript_path:$tp, decision:$dec, reason_code:$rc,
      threshold_lines:$thl, threshold_bytes:$thb, paths:$paths,
      est_tokens_avoided:$tok, est_tokens_uncapped:$toku,
      command:(if $cmd=="" then null else $cmd end),
      deny_count_for_path:$dc, latency_ms:$ms, pid:$pid}' 2>/dev/null)"
}

# ------------------------------------------------------------ deny state ----
# Deadlock breaker: after MAX_DENIES refusals of the same path in the same
# session we let it through. Guarantees no loop can survive, whatever happens
# to agent_type in a future Claude Code release.
shunt_deny_count() { # $1 abs path -> echoes the count INCLUDING this attempt
  local dir f key n now ttl
  dir=$(shunt_log_dir) || { printf '1'; return 0; }
  mkdir -p "$dir/state" 2>/dev/null || { printf '1'; return 0; }
  f="$dir/state/${SESSION_ID:-nosession}.denies"
  key=$(printf '%s' "$1" | sha256sum | cut -c1-32)
  now=$(date +%s)
  ttl="$DENY_TTL"
  n=1
  ( flock -x 9
    local prev_n prev_t
    read -r prev_n prev_t < <(awk -v k="$key" '$1==k {print $2, $3}' "$f" 2>/dev/null)
    if [ -n "${prev_t:-}" ] && [ $((now - prev_t)) -lt "$ttl" ]; then
      n=$((prev_n + 1))
    fi
    awk -v k="$key" '$1!=k' "$f" 2>/dev/null > "$f.tmp" || : > "$f.tmp"
    printf '%s\t%s\t%s\n' "$key" "$n" "$now" >> "$f.tmp"
    mv -f "$f.tmp" "$f" 2>/dev/null || true
    printf '%s' "$n" > "$f.count"
  ) 9>>"$f.lock" 2>/dev/null
  cat "$f.count" 2>/dev/null || printf '1'
}

# ------------------------------------------------------------- file probe ----
# Returns 0 and sets F_LINES / F_BYTES, or returns non-zero with F_REASON set.
shunt_probe() { # $1 path
  local f="$1" last
  F_LINES=0; F_BYTES=0; F_REASON=""
  [ -z "$f" ]      && { F_REASON="file_missing";     return 1; }
  [ -d "$f" ]      && { F_REASON="is_dir";           return 1; }
  [ -e "$f" ]      || { F_REASON="file_missing";     return 1; }
  # -f excludes FIFOs, devices and sockets. `wc -l /dev/zero` never returns.
  [ -f "$f" ]      || { F_REASON="not_regular_file"; return 1; }
  [ -r "$f" ]      || { F_REASON="unreadable";       return 1; }

  local ext="${f##*.}"
  if [ "$ext" != "$f" ]; then
    case " $EXEMPT_EXT " in *" ${ext,,} "*) F_REASON="extension_exempt"; return 1 ;; esac
  fi

  F_BYTES=$(stat -Lc%s "$f" 2>/dev/null) || { F_REASON="internal_error"; return 1; }
  [ "$F_BYTES" -eq 0 ] && { F_LINES=0; return 0; }

  # NUL byte in the first 8 KiB => binary; summarising it is pointless.
  local head_bytes stripped
  head_bytes=$(head -c 8192 "$f" 2>/dev/null | wc -c)
  stripped=$(head -c 8192 "$f" 2>/dev/null | tr -d '\0' | wc -c)
  [ "$head_bytes" != "$stripped" ] && { F_REASON="binary"; return 1; }

  F_LINES=$(wc -l < "$f" 2>/dev/null) || { F_REASON="internal_error"; return 1; }
  # wc -l counts newlines, so a file whose last line has no terminator is
  # undercounted by one. This is the classic off-by-one at the threshold.
  last=$(tail -c 1 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$last" != "0a" ] && F_LINES=$((F_LINES + 1))
  return 0
}

shunt_est_tokens() { # $1 bytes $2 lines -> tokens, incl. Read's line-number gutter
  awk -v b="$1" -v l="$2" 'BEGIN{ printf "%d", int(b/4) + int(l*1.5) }'
}

# Read truncates at ~2000 lines by default, so a 4000-line file never actually
# costs the parent 4000 lines. Costing the whole file would overstate savings.
shunt_capped_tokens() { # $1 path $2 bytes $3 lines -> tokens actually avoided
  local l="$3" b="$2"
  if [ "$SHUNT_HOOK" = "read_guard" ] && [ "$l" -gt "$TRUNC_LINES" ]; then
    l="$TRUNC_LINES"
    b=$(head -n "$TRUNC_LINES" "$1" 2>/dev/null | wc -c) || b="$2"
  fi
  shunt_est_tokens "$b" "$l"
}

shunt_json_escape() { printf '%s' "$1" | jq -Rs .; }
