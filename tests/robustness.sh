#!/usr/bin/env bash
# A hook that errors blocks the tool call. Every one of these must exit 0 and
# emit nothing, because a broken shunt must never be able to wedge a session.
set -uo pipefail
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SHUNT_LOG_DIR="$T/log"
seq 1 5000 | awk '{printf "line %d: lorem ipsum\n",$1}' > "$T/big.txt"
FAILED=0
feed(){ printf '%s' "$2" | bash "$P/hooks/$1" >"$T/out" 2>"$T/err"; echo $?; }
chk(){ if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: got=$2 want=$3"; FAILED=1; fi; }

for h in read-guard.sh bash-guard.sh; do
  chk "$h: not json"        "$(feed $h 'this is not json')" 0
  chk "$h:   empty stdin"   "$(feed $h '')" 0
  chk "$h:   empty object"  "$(feed $h '{}')" 0
  chk "$h:   null fields"   "$(feed $h '{"tool_name":null,"tool_input":null}')" 0
  chk "$h:   array payload" "$(feed $h '[1,2,3]')" 0
  chk "$h:   deep garbage"  "$(feed $h '{"tool_input":{"file_path":{"nested":true}}}')" 0
  chk "$h:   no stdout on garbage" "$(wc -c < "$T/out")" 0
done

# SubagentStop has no decision to emit, but the invariant is the same.
h=subagent-stop.sh
chk "$h: not json"        "$(feed $h 'this is not json')" 0
chk "$h:   empty stdin"   "$(feed $h '')" 0
chk "$h:   empty object"  "$(feed $h '{}')" 0
chk "$h:   array payload" "$(feed $h '[1,2,3]')" 0
chk "$h:   non-string fields" "$(feed $h '{"agent_type":{"x":1},"agent_id":[1]}')" 0
chk "$h:   no stdout on garbage" "$(wc -c < "$T/out")" 0

# A very long command must still produce a parseable, size-capped log line.
long="cat $(for i in $(seq 1 3000); do printf '/some/very/long/path/%d.txt ' $i; done)"
printf '{"tool_name":"Bash","session_id":"big","cwd":"%s","tool_input":{"command":%s}}' \
  "$T" "$(printf '%s' "$long" | jq -Rs .)" | bash "$P/hooks/bash-guard.sh" >/dev/null 2>&1
rc=$?
chk "huge command exits 0" "$rc" 0
line=$(tail -1 "$SHUNT_LOG_DIR"/events-*.jsonl 2>/dev/null)
chk "huge command logs valid JSON" "$(jq -e . >/dev/null 2>&1 <<<"$line" && echo yes || echo no)" yes
chk "log line stays under PIPE_BUF" "$([ "${#line}" -le 4096 ] && echo yes || echo no)" yes

# Concurrency: 200 parallel hooks, every line must be whole and parseable.
rm -rf "$SHUNT_LOG_DIR"; export SHUNT_LOG_DIR="$T/log2"
for i in $(seq 1 200); do
  printf '{"tool_name":"Read","session_id":"c%d","cwd":"%s","tool_input":{"file_path":"%s/big.txt"}}' "$i" "$T" "$T" \
    | bash "$P/hooks/read-guard.sh" >/dev/null 2>&1 &
  if [ $((i % 32)) -eq 0 ]; then wait; fi
done; wait
n=$(cat "$SHUNT_LOG_DIR"/events-*.jsonl 2>/dev/null | wc -l)
ok=$(cat "$SHUNT_LOG_DIR"/events-*.jsonl 2>/dev/null | jq -e . >/dev/null 2>&1 <<<"$(cat "$SHUNT_LOG_DIR"/events-*.jsonl | head -0)"; \
     cat "$SHUNT_LOG_DIR"/events-*.jsonl | while read -r l; do jq -e . >/dev/null 2>&1 <<<"$l" || echo bad; done | wc -l)
chk "200 concurrent appends land 200 lines" "$n" 200
chk "no interleaved/corrupt lines" "$ok" 0
exit $FAILED
