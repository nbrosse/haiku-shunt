#!/usr/bin/env bash
# The deadlock breaker. Guard A (agent_type) is documented but not guaranteed;
# if a future Claude Code stops sending it, the worker's own read would be
# denied and every large file would wedge. After N refusals of the same path in
# the same session we let it through, so no loop can survive whatever happens
# upstream. Needs state across invocations, so it cannot be a single-shot case.
set -uo pipefail
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SHUNT_LOG_DIR="$T/log"
seq 1 5000 | awk '{printf "line %d: lorem ipsum dolor sit\n",$1}' > "$T/big.txt"
seq 1 5000 | awk '{printf "line %d: lorem ipsum dolor sit\n",$1}' > "$T/other.txt"
FAILED=0
try(){ # $1 session  $2 path -> prints decision
  printf '{"tool_name":"Read","session_id":"%s","cwd":"%s","tool_input":{"file_path":"%s"}}' "$1" "$T" "$2" \
    | bash "$P/hooks/read-guard.sh" | { out=$(cat); [ -z "$out" ] && echo none || jq -r ".hookSpecificOutput.permissionDecision // \"none\"" <<<"$out"; }
}
chk(){ if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: got=$2 want=$3"; FAILED=1; fi; }

chk "first attempt denies"            "$(try s1 "$T/big.txt")"   deny
chk "second attempt denies"           "$(try s1 "$T/big.txt")"   deny
chk "third attempt is let through"    "$(try s1 "$T/big.txt")"   none
chk "and stays through afterwards"    "$(try s1 "$T/big.txt")"   none
chk "cap is per-path"                 "$(try s1 "$T/other.txt")" deny
chk "cap is per-session"              "$(try s2 "$T/big.txt")"   deny
chk "cap raised by env"               "$(SHUNT_MAX_DENIES_PER_PATH=5 try s3 "$T/big.txt")" deny

# 20 concurrent denies on one path must leave the state file intact.
for i in $(seq 1 20); do try s4 "$T/big.txt" >/dev/null & done; wait
lines=$(wc -l < "$SHUNT_LOG_DIR/state/s4.denies" 2>/dev/null || echo 0)
chk "concurrent denies keep one state row" "$lines" 1
bad=$(awk 'NF!=3' "$SHUNT_LOG_DIR/state/s4.denies" 2>/dev/null | wc -l)
chk "no malformed state rows" "$bad" 0
exit $FAILED
