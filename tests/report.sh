#!/usr/bin/env bash
# `report` only counts: how often each hook fired, why, and how big the denied
# files were. The size buckets are what makes tuning the threshold possible
# without a cost model: they say how many denies another value would change.
set -uo pipefail
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SHUNT_LOG_DIR="$T/log"; mkdir -p "$SHUNT_LOG_DIR"
LOG="$SHUNT_LOG_DIR/events-2026-01-01.jsonl"
FAILED=0
chk(){ if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: got=$2 want=$3"; FAILED=1; fi; }
rep(){ "$P/bin/haiku-shunt" report --format json "$@" 2>/dev/null; }

# Nothing logged yet: not an error.
"$P/bin/haiku-shunt" report >/dev/null 2>&1
chk "empty log exits 0" "$?" 0

d(){ # $1 hook $2 decision $3 reason $4 paths-json
  printf '{"v":1,"ts":"2026-01-01T00:00:00.000Z","event":"hook_decision","hook":"%s","decision":"%s","reason_code":"%s","latency_ms":5,"paths":%s}\n' \
    "$1" "$2" "$3" "$4" >> "$LOG"
}
d read_guard deny over_threshold '[{"abs":"/a","exists":true,"lines":420,"bytes":20000}]'
d read_guard deny over_threshold '[{"abs":"/b","exists":true,"lines":4000,"bytes":200000}]'
d read_guard none under_threshold '[{"abs":"/c","exists":true,"lines":40,"bytes":900}]'
d read_guard none targeted_read '[]'
# Bash: the bucket is what reached stdout (effective_lines), not the file size.
d bash_guard deny over_threshold '[{"abs":"/s","exists":true,"lines":30,"effective_lines":30,"bytes":600},{"abs":"/d","exists":true,"lines":5000,"effective_lines":800,"bytes":90000}]'
# A deny on byte size alone (minified bundle): one line, still counted.
d read_guard deny over_threshold '[{"abs":"/m","exists":true,"lines":1,"bytes":300000}]'

J=$(rep)
chk "hook calls"        "$(jq -r .hook_calls <<<"$J")" 6
chk "denies"            "$(jq -r .denies     <<<"$J")" 4
chk "reasons"           "$(jq -c '.reasons | to_entries | map("\(.key)=\(.value)") | sort' <<<"$J")" \
                        '["deny/over_threshold=4","none/targeted_read=1","none/under_threshold=1"]'
chk "size buckets"      "$(jq -c .deny_size_buckets <<<"$J")" \
                        '{"<350":1,"350-500":1,"500-1000":1,"1000-2000":0,"2000+":1}'
chk "table format runs" "$("$P/bin/haiku-shunt" report >/dev/null 2>&1; echo $?)" 0
exit $FAILED
