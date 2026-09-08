#!/usr/bin/env bash
# Deterministic hook evals. No Claude Code, no network, no API cost.
#
#   bash evals/run.sh [--filter REGEX] [--hook read|bash] [-v] [--keep]
#
# Asserts on the CURRENT hook contract: a deny is
# hookSpecificOutput.permissionDecision == "deny"; an allow is NO output at all
# (emitting "allow" would override the user's own permission rules).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
FILTER=""; ONLY_HOOK=""; VERBOSE=0; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --filter) FILTER="$2"; shift 2 ;;
    --hook)   ONLY_HOOK="$2"; shift 2 ;;
    -v|--verbose) VERBOSE=1; shift ;;
    --keep)   KEEP=1; shift ;;
    *) shift ;;
  esac
done

PASS=0; FAIL=0; SKIP=0; N=0
RUNDIR=$(mktemp -d /tmp/haiku-shunt-evals.XXXXXX)
[ "$KEEP" = "1" ] || trap 'rm -rf "$RUNDIR"' EXIT
FIX="$RUNDIR/fixtures"; mkdir -p "$FIX"

red(){ printf '\033[31m%s\033[0m' "$1"; }
grn(){ printf '\033[32m%s\033[0m' "$1"; }
dim(){ printf '\033[2m%s\033[0m' "$1"; }

make_fixture() { # $1 id  $2 spec-json
  local id="$1" spec="$2" mode lines bytes target path
  mode=$(jq -r '.mode // "seq"' <<<"$spec")
  lines=$(jq -r '.lines // 0' <<<"$spec")
  bytes=$(jq -r '.bytes // 0' <<<"$spec")
  target=$(jq -r '.target // ""' <<<"$spec")
  path="$FIX/$(jq -r --arg i "$id" '.name // ($i + ".txt")' <<<"$spec")"
  mkdir -p "$(dirname "$path")"
  case "$mode" in
    seq)      seq 1 "$lines" | awk '{printf "line %d: lorem ipsum dolor sit amet consectetur\n",$1}' > "$path" ;;
    tiny)     seq 1 "$lines" | awk '{printf "%d\n",$1}' > "$path" ;;   # many lines, few bytes
    nonewline) seq 1 "$lines" | awk '{printf "line %d: lorem ipsum dolor sit amet consectetur\n",$1}' > "$path"
               printf 'no trailing newline' >> "$path"
               truncate -s -1 "$path" 2>/dev/null || true
               # rebuild precisely: N lines, last one unterminated
               { seq 1 $((lines-1)) | awk '{printf "line %d: lorem ipsum dolor sit amet consectetur\n",$1}'
                 printf 'line %d: no trailing newline' "$lines"; } > "$path" ;;
    empty)    : > "$path" ;;
    minified) head -c "$bytes" /dev/urandom | base64 | tr -d '\n' > "$path"; truncate -s "$bytes" "$path" ;;
    binary)   head -c "$bytes" /dev/urandom > "$path" ;;
    dir)      rm -f "$path"; mkdir -p "$path" ;;
    symlink)  ln -sfn "$FIX/$target" "$path" ;;
    dangling) ln -sfn "$FIX/definitely-not-here" "$path" ;;
    missing)  rm -rf "$path" ;;
    unreadable) seq 1 "$lines" | awk '{printf "line %d: lorem\n",$1}' > "$path"; chmod 000 "$path" ;;
  esac
  printf '%s' "$path"
}

run_case() {
  local case_json hook name expect_dec expect_rc expect_exit reason_re reason_not max_ms
  case_json="$1"
  name=$(jq -r '.name' <<<"$case_json")
  hook=$(jq -r '.hook' <<<"$case_json")
  [ -n "$FILTER" ] && ! [[ "$name" =~ $FILTER ]] && return 0
  [ -n "$ONLY_HOOK" ] && [ "$hook" != "$ONLY_HOOK" ] && return 0
  if [ "$(jq -r '.skip // false' <<<"$case_json")" = "true" ]; then
    SKIP=$((SKIP+1)); printf '  %s %s\n' "$(dim skip)" "$name"; return 0
  fi
  N=$((N+1))

  # Fixtures, fresh per case so state (perms, symlinks) cannot leak.
  rm -rf "$FIX"; mkdir -p "$FIX"
  local payload; payload=$(jq -c '.input' <<<"$case_json")
  local ids; ids=$(jq -r '(.fixtures // {}) | keys[]?' <<<"$case_json")
  for id in $ids; do
    local spec p
    spec=$(jq -c --arg i "$id" '.fixtures[$i]' <<<"$case_json")
    p=$(make_fixture "$id" "$spec")
    payload=$(jq -c --arg k "@FIX:$id@" --arg v "$p" \
      'walk(if type=="string" then gsub($k; $v) else . end)' <<<"$payload")
  done
  payload=$(jq -c --arg v "$FIX" 'walk(if type=="string" then gsub("@FIX@"; $v) else . end)' <<<"$payload")

  local logdir="$RUNDIR/log/$N"; mkdir -p "$logdir"
  local envs=(); while IFS='=' read -r k v; do [ -n "$k" ] && envs+=("$k=$v"); done \
    < <(jq -r '(.env // {}) | to_entries[] | "\(.key)=\(.value)"' <<<"$case_json")

  local script="$PLUGIN/hooks/read-guard.sh"
  [ "$hook" = "bash" ] && script="$PLUGIN/hooks/bash-guard.sh"

  local t0 t1 out rc
  t0=$(date +%s%N)
  out=$(printf '%s' "$payload" | env SHUNT_LOG_DIR="$logdir" "${envs[@]}" \
        timeout 10 bash "$script" 2>"$RUNDIR/err"); rc=$?
  t1=$(date +%s%N)
  local ms=$(( (t1-t0)/1000000 ))

  local dec="none"
  if [ -n "$out" ]; then
    dec=$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$out" 2>/dev/null) || dec="MALFORMED"
  fi
  local rec rc_actual
  rec=$(tail -1 "$logdir"/events-*.jsonl 2>/dev/null)
  rc_actual=$(jq -r '.reason_code // ""' <<<"$rec" 2>/dev/null)

  expect_dec=$(jq -r '.expect.decision' <<<"$case_json")
  expect_rc=$(jq -r '.expect.reason_code // ""' <<<"$case_json")
  expect_exit=$(jq -r '.expect.exit_code // 0' <<<"$case_json")
  reason_re=$(jq -r '.expect.reason_matches // ""' <<<"$case_json")
  reason_not=$(jq -r '.expect.reason_not_matches // ""' <<<"$case_json")
  max_ms=$(jq -r '.expect.max_latency_ms // 0' <<<"$case_json")

  local errs=()
  [ "$rc" != "$expect_exit" ] && errs+=("exit=$rc want=$expect_exit")
  [ "$dec" != "$expect_dec" ] && errs+=("decision=$dec want=$expect_dec")
  [ -n "$expect_rc" ] && [ "$rc_actual" != "$expect_rc" ] && errs+=("reason_code=$rc_actual want=$expect_rc")
  if [ -n "$out" ]; then
    jq -e . >/dev/null 2>&1 <<<"$out" || errs+=("stdout is not JSON")
  fi
  if [ "$expect_dec" = "deny" ]; then
    local reason; reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$out" 2>/dev/null)
    [ -n "$reason_re" ] && ! grep -qE "$reason_re" <<<"$reason" && errs+=("reason missing /$reason_re/")
    [ -n "$reason_not" ] && grep -qE "$reason_not" <<<"$reason" && errs+=("reason matched forbidden /$reason_not/")
  fi
  [ "$max_ms" != "0" ] && [ "$ms" -gt "$max_ms" ] && errs+=("latency ${ms}ms > ${max_ms}ms")

  if [ ${#errs[@]} -eq 0 ]; then
    PASS=$((PASS+1)); printf '  %s %-46s %s\n' "$(grn ok)" "$name" "$(dim "$(jq -r '.why // ""' <<<"$case_json")")"
  else
    FAIL=$((FAIL+1))
    printf '  %s %-46s %s\n' "$(red FAIL)" "$name" "$(red "${errs[*]}")"
    if [ "$VERBOSE" = "1" ]; then
      printf '       payload: %s\n' "$payload"
      printf '       stdout : %s\n' "${out:-<empty>}"
      printf '       log    : %s\n' "${rec:-<none>}"
      [ -s "$RUNDIR/err" ] && printf '       stderr : %s\n' "$(cat "$RUNDIR/err")"
    fi
  fi
}

for f in "$HERE"/cases/*.json; do
  [ -e "$f" ] || continue
  echo; echo "$(basename "$f" .json)"
  echo "────────────────────────────────────────────────────────────────────────"
  n=$(jq '.cases | length' "$f")
  for ((i=0;i<n;i++)); do run_case "$(jq -c ".cases[$i]" "$f")"; done
done

# Unit tests that are not hook cases but must gate the same CI run.
for t in "$PLUGIN"/tests/*.sh; do
  [ -e "$t" ] || continue
  echo; echo "$(basename "$t" .sh)"
  echo "────────────────────────────────────────────────────────────────────────"
  if out=$(bash "$t" 2>&1); then
    echo "$out" | sed 's/^/  /'
    p=$(grep -c '^ok' <<<"$out" || true); PASS=$((PASS+p)); N=$((N+p))
  else
    echo "$out" | sed 's/^/  /'
    f2=$(grep -c '^FAIL' <<<"$out" || true); [ "$f2" = "0" ] && f2=1
    FAIL=$((FAIL+f2)); N=$((N+f2))
  fi
done

echo
echo "════════════════════════════════════════════════════════════════════════"
printf 'Total: %s passed, %s failed, %s skipped (%s cases)\n' \
  "$(grn "$PASS")" "$( [ "$FAIL" -gt 0 ] && red "$FAIL" || echo 0 )" "$SKIP" "$N"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
