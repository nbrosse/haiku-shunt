#!/usr/bin/env bash
# session-cost is the A/B metric: it must price the parent AND every subagent
# from the transcripts' own usage rows. Leaving the subagents out would make
# the shunt arm look free, since that is precisely where its cost moved.
set -uo pipefail
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILED=0
chk(){ if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: got=$2 want=$3"; FAILED=1; fi; }
near(){
  awk -v a="$2" -v w="$3" -v t="${4:-0.000001}" -v l="$1" \
    'BEGIN{ if ((a-w)<t && (w-a)<t) printf "ok %s\n", l; else printf "FAIL %s: got=%s want=%s\n", l, a, w }'
  awk -v a="$2" -v w="$3" -v t="${4:-0.000001}" 'BEGIN{ exit !((a-w)<t && (w-a)<t) }' || FAILED=1
}

SESS="$T/proj/11111111-2222-3333-4444-555555555555"
mkdir -p "$SESS/subagents"
# Parent on Opus ($5 in / $25 out), two messages, blocks repeated as Claude
# Code really writes them.
cat > "$SESS.jsonl" <<'EOF'
{"type":"assistant","message":{"id":"msg_P1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0}}}
{"type":"assistant","message":{"id":"msg_P1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":50,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0}}}
{"type":"assistant","message":{"id":"msg_P2","model":"claude-opus-5","usage":{"input_tokens":20,"output_tokens":100,"cache_creation_input_tokens":500,"cache_read_input_tokens":1000}}}
EOF
# One Haiku worker ($1 in / $5 out).
cat > "$SESS/subagents/agent-abc123.jsonl" <<'EOF'
{"type":"assistant","message":{"id":"msg_W1","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":100,"output_tokens":200,"cache_creation_input_tokens":2000,"cache_read_input_tokens":0}}}
EOF
echo '{"agentType":"haiku-shunt:bulk-reader","toolUseId":"tu_1","spawnDepth":1}' \
  > "$SESS/subagents/agent-abc123.meta.json"

J=$("$P/bin/haiku-shunt" session-cost "$SESS.jsonl" --format json)

# parent = (30*5 + 1500*1.25*5 + 1000*0.10*5 + 150*25) / 1e6 = 0.013775
near "parent priced at its own model's rates" "$(jq -r .parent_usd <<<"$J")" 0.013775
# worker = (100*1 + 2000*1.25*1 + 200*5) / 1e6                = 0.003600
near "worker priced at the worker's rates"    "$(jq -r .worker_usd <<<"$J")" 0.003600
near "total is parent + workers"              "$(jq -r .total_usd  <<<"$J")" 0.017375
# Three rows, two messages: a turn is a message, not a content block.
chk  "assistant turns counted per message"    "$(jq -r .assistant_turns <<<"$J")" 2
chk  "worker is attributed to its agent"      "$(jq -r '.workers[0].agent_type' <<<"$J")" "haiku-shunt:bulk-reader"

# The output-per-block trap applies to the parent too: msg_P1's blocks are
# 5 then 50, and only 50 is real.
chk "parent output uses max per message, not sum" "$(jq -r .parent.output_tokens <<<"$J")" 150

# A session with no subagents must still price, and must not invent workers.
S2="$T/proj/99999999-2222-3333-4444-555555555555"
cp "$SESS.jsonl" "$S2.jsonl"
J2=$("$P/bin/haiku-shunt" session-cost "$S2.jsonl" --format json)
chk  "no subagents -> no workers" "$(jq -r '.workers | length' <<<"$J2")" 0
near "no subagents -> total is parent" "$(jq -r .total_usd <<<"$J2")" 0.013775

# analyze measures R, the parent turns after a delegation, and must count
# messages, not rows: msg_P3 and msg_P4 are two turns written as four rows.
S3="$T/proj/33333333-2222-3333-4444-555555555555"
mkdir -p "$S3/subagents" "$T/log3"
cat > "$S3.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T00:00:01Z","message":{"id":"msg_P1","model":"claude-opus-5","usage":{"output_tokens":1}}}
{"type":"assistant","timestamp":"2026-01-01T00:00:10Z","message":{"id":"msg_P3","model":"claude-opus-5","usage":{"output_tokens":1}}}
{"type":"assistant","timestamp":"2026-01-01T00:00:11Z","message":{"id":"msg_P3","model":"claude-opus-5","usage":{"output_tokens":9}}}
{"type":"assistant","timestamp":"2026-01-01T00:00:20Z","message":{"id":"msg_P4","model":"claude-opus-5","usage":{"output_tokens":1}}}
{"type":"assistant","timestamp":"2026-01-01T00:00:21Z","message":{"id":"msg_P4","model":"claude-opus-5","usage":{"output_tokens":9}}}
EOF
echo '{"type":"assistant","timestamp":"2026-01-01T00:00:05Z","message":{"id":"msg_W1","model":"claude-haiku-4-5-20251001","usage":{"output_tokens":5}}}' \
  > "$S3/subagents/agent-r1.jsonl"
echo '{"agentType":"haiku-shunt:bulk-reader"}' > "$S3/subagents/agent-r1.meta.json"
SHUNT_LOG_DIR="$T/log3" "$P/bin/haiku-shunt" analyze "$S3.jsonl" --write >/dev/null
chk "analyze: R counts messages after the delegation, not rows" \
  "$(jq -r .turns_remaining "$T"/log3/events-*.jsonl)" 2

# Resolving by session id must find the same file as the explicit path.
chk "unknown session id fails loudly" \
  "$("$P/bin/haiku-shunt" session-cost deadbeef-0000-0000-0000-000000000000 >/dev/null 2>&1; echo $?)" 1
exit $FAILED
