#!/usr/bin/env bash
# Old event logs and deny state are pruned on the first record of a new day;
# SHUNT_LOG_RETENTION_DAYS=0 keeps everything.
set -uo pipefail
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILED=0
chk(){ if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: got=$2 want=$3"; FAILED=1; fi; }
payload='{"tool_name":"Read","session_id":"r","cwd":"/","tool_input":{"file_path":"/nonexistent"}}'

seed(){ # $1 dir
  mkdir -p "$1/state"
  echo '{}' > "$1/events-2000-01-01.jsonl"; touch -d '40 days ago' "$1/events-2000-01-01.jsonl"
  echo '{}' > "$1/events-2000-02-01.jsonl"; touch -d '5 days ago'  "$1/events-2000-02-01.jsonl"
  : > "$1/state/old.denies"; touch -d '40 days ago' "$1/state/old.denies"
}

seed "$T/a"
SHUNT_LOG_DIR="$T/a" bash "$P/hooks/read-guard.sh" <<<"$payload" >/dev/null
chk "old log pruned"      "$(ls "$T/a" | grep -c 2000-01-01)" 0
chk "recent log kept"     "$(ls "$T/a" | grep -c 2000-02-01)" 1
chk "old deny state pruned" "$(ls "$T/a/state" | grep -c old.denies)" 0

seed "$T/b"
SHUNT_LOG_DIR="$T/b" SHUNT_LOG_RETENTION_DAYS=0 bash "$P/hooks/read-guard.sh" <<<"$payload" >/dev/null
chk "retention 0 keeps everything" "$(ls "$T/b" | grep -c 2000-01-01)" 1
exit $FAILED
