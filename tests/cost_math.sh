#!/usr/bin/env bash
# The arithmetic behind every number the report prints, pinned to hand-computed
# values. If someone "simplifies" the cost model, these break.
set -uo pipefail
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SHUNT_LOG_DIR="$T/log"; mkdir -p "$SHUNT_LOG_DIR"
LOG="$SHUNT_LOG_DIR/events-2026-01-01.jsonl"
FAILED=0

chk(){ if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: got=$2 want=$3"; FAILED=1; fi; }
near(){ # $1 label $2 actual $3 want $4 tolerance
  awk -v a="$2" -v w="$3" -v t="${4:-0.000001}" -v l="$1" \
    'BEGIN{ if ((a-w)<t && (w-a)<t) printf "ok %s\n", l; else printf "FAIL %s: got=%s want=%s\n", l, a, w }'
  awk -v a="$2" -v w="$3" -v t="${4:-0.000001}" 'BEGIN{ exit !((a-w)<t && (w-a)<t) }' || FAILED=1
}
rep(){ "$P/bin/haiku-shunt" report --format json "$@" 2>/dev/null; }

cat > "$LOG" <<'EOF'
{"v":1,"ts":"2026-01-01T00:00:00.000Z","event":"hook_decision","hook":"read_guard","tool_name":"Read","session_id":"s","decision":"deny","reason_code":"over_threshold","est_tokens_avoided":40000,"est_tokens_uncapped":40000,"latency_ms":10,"paths":[]}
{"v":1,"ts":"2026-01-01T00:00:01.000Z","event":"delegation","phase":"stop","worker_agent_id":"w1","worker_agent_type":"bulk-reader","usage":{"requests":3,"model":"claude-haiku-4-5-20251001","input_tokens":200,"cache_creation_input_tokens":41000,"cache_read_input_tokens":0,"output_tokens":400},"usage_source":"subagent_transcript","status":"ok"}
EOF

# Sonnet parent, 10 turns remaining, perfect cache hits.
#   factor  = 1.25 + 0.10*10                        = 2.25
#   gross   = 40000 * $2.00 * 2.25 / 1e6            = 0.180000
#   overhead= (140+200+300) * $2.00 * 2.25 / 1e6    = 0.002880
#   worker  = (200*1 + 41000*1.25*1 + 400*5) / 1e6  = 0.053450
#   net     = 0.180000 - 0.002880 - 0.053450        = 0.123670
J=$(rep --parent claude-sonnet-5 --turns 10 --cache-hit 1.0)
near "gross at R=10, h=1.0"    "$(jq -r .gross_usd       <<<"$J")" 0.180000
near "overhead at R=10"        "$(jq -r .overhead_usd    <<<"$J")" 0.002880
near "worker cost is measured" "$(jq -r .worker_cost_usd <<<"$J")" 0.053450
near "net"                     "$(jq -r .net_usd         <<<"$J")" 0.123670
chk  "usage counted as measured" "$(jq -r .measured <<<"$J")" 1

# R=0 collapses to the naive figure plus the cache-write surcharge.
near "gross at R=0"  "$(jq -r .gross_usd <<<"$(rep --parent claude-sonnet-5 --turns 0 --cache-hit 1.0)")" 0.100000
# A total cache miss is the ceiling: factor = 1.25 + 1.0*10 = 11.25
near "gross at h=0"  "$(jq -r .gross_usd <<<"$(rep --parent claude-sonnet-5 --turns 10 --cache-hit 0.0)")" 0.900000
# Opus is 2.5x Sonnet on input, so the same read is worth 2.5x more to shunt.
near "gross on Opus" "$(jq -r .gross_usd <<<"$(rep --parent claude-opus-5 --turns 10 --cache-hit 1.0)")" 0.450000

# Break-even: (14600*1.25*1 + 500*5) / (2.00*2.25 - 1.25*1) = 20750/3.25
near "break-even tokens" "$(jq -r .breakeven_tokens <<<"$(rep --parent claude-sonnet-5 --turns 10 --cache-hit 1.0 --worker-floor 14600)")" 6385 1
# and the floor really is taken from measured delegations when not pinned:
# (41000*1.25 + 2500)/3.25 = 16538
near "break-even uses measured floor" "$(jq -r .breakeven_tokens <<<"$(rep --parent claude-sonnet-5 --turns 10 --cache-hit 1.0)")" 16538 1

# Degenerate input must not divide by zero.
: > "$LOG"
echo '{"v":1,"ts":"2026-01-01T00:00:00.000Z","event":"hook_decision","hook":"read_guard","decision":"none","reason_code":"under_threshold","latency_ms":1,"paths":[]}' >> "$LOG"
J0=$(rep --parent claude-sonnet-5 --turns 10 --cache-hit 1.0)
near "no delegations -> zero net" "$(jq -r .net_usd <<<"$J0")" 0.0
chk  "no delegations -> exit ok"  "$?" 0

# THE regression test. Claude Code writes one transcript row per content block
# and repeats the message's usage on each. Summing rows overcounts ~3x; taking
# the first row per message.id undercounts output ~60x, because output_tokens
# grows across blocks while the input side stays constant. Both were observed
# on a real transcript.
cat > "$T/worker.jsonl" <<'EOF'
{"type":"assistant","message":{"id":"msg_A","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10,"output_tokens":3,"cache_creation_input_tokens":14598,"cache_read_input_tokens":0}}}
{"type":"assistant","message":{"id":"msg_A","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10,"output_tokens":3,"cache_creation_input_tokens":14598,"cache_read_input_tokens":0}}}
{"type":"assistant","message":{"id":"msg_A","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10,"output_tokens":342,"cache_creation_input_tokens":14598,"cache_read_input_tokens":0}}}
{"type":"assistant","message":{"id":"msg_B","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":5,"output_tokens":1,"cache_creation_input_tokens":4704,"cache_read_input_tokens":66080}}}
{"type":"assistant","message":{"id":"msg_B","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":5,"output_tokens":327,"cache_creation_input_tokens":4704,"cache_read_input_tokens":66080}}}
EOF
U=$(jq -s -f "$P/hooks/lib/usage.jq" "$T/worker.jsonl")
chk "jq dedupe: requests"       "$(jq -r .requests <<<"$U")" 2
chk "jq dedupe: cache-write"    "$(jq -r .cache_creation_input_tokens <<<"$U")" 19302
chk "jq dedupe: cache-read"     "$(jq -r .cache_read_input_tokens <<<"$U")" 66080
chk "jq dedupe: output uses max, not first" "$(jq -r .output_tokens <<<"$U")" 669
chk "jq dedupe: input not multiplied"       "$(jq -r .input_tokens  <<<"$U")" 15

# The Python aggregator must agree with the jq one, or the live hook and the
# post-hoc analyzer will report different costs for the same delegation.
PY_U=$(HS="$P/bin/haiku-shunt" WJ="$T/worker.jsonl" python3 -c "
import json, os
ns = {'__name__': 'haiku_shunt_under_test', '__file__': os.environ['HS']}  # not __main__, so main() never runs
exec(compile(open(os.environ['HS']).read(), 'haiku-shunt', 'exec'), ns)
rows = [json.loads(l) for l in open(os.environ['WJ'])]
print(json.dumps(ns['aggregate_usage'](rows), sort_keys=True))
")
chk "python aggregator matches jq" "$(jq -S -c 'del(.model)' <<<"$PY_U")" "$(jq -S -c 'del(.model)' <<<"$U")"

# group_by sorts by message.id, which is random -- so the LAST group is not the
# last message. These ids sort backwards on purpose: msg_zzz is first in time.
# Get this wrong and summary_tokens reports the wrong message's output.
cat > "$T/rev.jsonl" <<'EOF'
{"type":"assistant","message":{"id":"msg_zzz","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10,"output_tokens":342,"cache_creation_input_tokens":14598,"cache_read_input_tokens":0}}}
{"type":"assistant","message":{"id":"msg_aaa","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":5,"output_tokens":327,"cache_creation_input_tokens":4704,"cache_read_input_tokens":66080}}}
EOF
RV=$(jq -s -f "$P/hooks/lib/usage.jq" "$T/rev.jsonl")
chk "final_output_tokens is chronological, not id-sorted" "$(jq -r .final_output_tokens <<<"$RV")" 327
chk "final_output_tokens != total output"                 "$(jq -r .output_tokens        <<<"$RV")" 669
PY_RV=$(HS="$P/bin/haiku-shunt" WJ="$T/rev.jsonl" python3 -c "
import json, os
ns = {'__name__': 'haiku_shunt_under_test', '__file__': os.environ['HS']}
exec(compile(open(os.environ['HS']).read(), 'haiku-shunt', 'exec'), ns)
print(json.dumps(ns['aggregate_usage']([json.loads(l) for l in open(os.environ['WJ'])])))
")
chk "python agrees on the final message" "$(jq -r .final_output_tokens <<<"$PY_RV")" 327

# R is measured, not assumed, once `analyze --write` has counted the parent
# turns that followed each delegation. Median of 4 and 8 is 6.
cat > "$LOG" <<'EOF'
{"v":1,"ts":"2026-01-01T00:00:00.000Z","event":"hook_decision","hook":"read_guard","tool_name":"Read","session_id":"s","decision":"deny","reason_code":"over_threshold","est_tokens_avoided":40000,"est_tokens_uncapped":40000,"latency_ms":10,"paths":[]}
{"v":1,"ts":"2026-01-01T00:00:01.000Z","event":"delegation","phase":"backfill","worker_agent_id":"w1","worker_agent_base":"bulk-reader","turns_remaining":4,"usage":{"requests":2,"model":"claude-haiku-4-5-20251001","input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}
{"v":1,"ts":"2026-01-01T00:00:02.000Z","event":"delegation","phase":"backfill","worker_agent_id":"w2","worker_agent_base":"bulk-reader","turns_remaining":8,"usage":{"requests":2,"model":"claude-haiku-4-5-20251001","input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}
EOF
JT=$(rep --parent claude-sonnet-5 --cache-hit 1.0)
chk "R is the median of measured turns_remaining" "$(jq -r .turns        <<<"$JT")" 6
chk "and says so"                                 "$(jq -r .turns_source <<<"$JT")" "measured from 2 delegation(s)"
chk "--turns still wins" "$(jq -r .turns_source <<<"$(rep --parent claude-sonnet-5 --turns 3)")" "pinned by --turns"

# A measured summary replaces the 300-token assumption in the overhead line.
#   (140 deny + 200 prompt + 900 summary) * $2.00 * 2.25 / 1e6 = 0.005580
cat > "$LOG" <<'EOF'
{"v":1,"ts":"2026-01-01T00:00:00.000Z","event":"hook_decision","hook":"read_guard","tool_name":"Read","session_id":"s","decision":"deny","reason_code":"over_threshold","est_tokens_avoided":40000,"est_tokens_uncapped":40000,"latency_ms":10,"paths":[]}
{"v":1,"ts":"2026-01-01T00:00:01.000Z","event":"delegation","phase":"stop","worker_agent_id":"w1","worker_agent_base":"bulk-reader","summary_tokens":900,"usage":{"requests":2,"model":"claude-haiku-4-5-20251001","input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1000}}
EOF
near "measured summary drives overhead" \
  "$(jq -r .overhead_usd <<<"$(rep --parent claude-sonnet-5 --turns 10 --cache-hit 1.0)")" 0.005580

# Every deny pays its reason, not just the ones that led to a delegation: the
# model usually answers a deny with windowed reads. 3 denies, 1 delegation:
#   (3*140 deny + 200 prompt + 300 summary) * $2.00 * 2.25 / 1e6 = 0.004140
: > "$LOG"
for i in 1 2 3; do
  echo '{"v":1,"ts":"2026-01-01T00:00:00.000Z","event":"hook_decision","hook":"read_guard","decision":"deny","reason_code":"over_threshold","est_tokens_avoided":40000,"est_tokens_uncapped":40000,"latency_ms":10,"paths":[]}' >> "$LOG"
done
echo '{"v":1,"ts":"2026-01-01T00:00:01.000Z","event":"delegation","phase":"stop","worker_agent_id":"w1","worker_agent_base":"bulk-reader","usage":{"requests":1,"model":"claude-haiku-4-5-20251001","input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}' >> "$LOG"
near "deny reason charged per deny, not per delegation" \
  "$(jq -r .overhead_usd <<<"$(rep --parent claude-sonnet-5 --turns 10 --cache-hit 1.0)")" 0.004140

# code-writer: the saving is on the OUTPUT side, and it pays no deny reason.
#   content  = 5000 output - 200 summary                    = 4800
#   saving   = 4800 * ($10.00 out + $2.00 in * 2.25) / 1e6  = 0.069600
#   overhead = (200 prompt + 200 summary) * $2.00 * 2.25/1e6= 0.001800
#   worker   = (100 + 20000*1.25 + 5000*5) / 1e6            = 0.050100
#   net      = 0.069600 - 0.001800 - 0.050100               = 0.017700
cat > "$LOG" <<'EOF'
{"v":1,"ts":"2026-01-01T00:00:01.000Z","event":"delegation","phase":"stop","worker_agent_id":"cw1","worker_agent_type":"haiku-shunt:code-writer","worker_agent_base":"code-writer","summary_tokens":200,"usage":{"requests":2,"model":"claude-haiku-4-5-20251001","input_tokens":100,"cache_creation_input_tokens":20000,"cache_read_input_tokens":0,"output_tokens":5000}}
EOF
JW=$(rep --parent claude-sonnet-5 --turns 10 --cache-hit 1.0)
chk  "write tokens exclude the summary" "$(jq -r .write_tokens_avoided <<<"$JW")" 4800
near "write saving"                     "$(jq -r .write_gross_usd <<<"$JW")" 0.069600
near "a code-writer pays no deny reason" "$(jq -r .overhead_usd   <<<"$JW")" 0.001800
near "code-writer is net positive"      "$(jq -r .net_usd         <<<"$JW")" 0.017700
# and it must not be counted as a read: no denies, so no read-side saving.
near "no read saving from a write"      "$(jq -r .gross_usd       <<<"$JW")" 0.0

exit $FAILED
