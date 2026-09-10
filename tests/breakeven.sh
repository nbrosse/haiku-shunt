#!/usr/bin/env bash
# The break-even formula `doctor` prints, pinned to hand-computed values. It is
# the one piece of the cost model that survives: no data needed, just prices,
# the worker's fixed cache write, R and h. Cost itself is measured by A/B.
set -uo pipefail
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILED=0
near(){ # $1 label $2 actual $3 want $4 tolerance
  awk -v a="$2" -v w="$3" -v t="${4:-0.000001}" -v l="$1" \
    'BEGIN{ if ((a-w)<t && (w-a)<t) printf "ok %s\n", l; else printf "FAIL %s: got=%s want=%s\n", l, a, w }'
  awk -v a="$2" -v w="$3" -v t="${4:-0.000001}" 'BEGIN{ exit !((a-w)<t && (w-a)<t) }' || FAILED=1
}
chk(){ if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: got=$2 want=$3"; FAILED=1; fi; }

# Load bin/haiku-shunt as a module, not __main__, so main() never runs.
py(){ HS="$P/bin/haiku-shunt" python3 -c "
import os
ns = {'__name__': 'haiku_shunt_under_test', '__file__': os.environ['HS']}
exec(compile(open(os.environ['HS']).read(), 'haiku-shunt', 'exec'), ns)
globals().update(ns)
$1"; }

# factor = 1.25 + mu*R, mu = 0.10h + 1.0(1-h)
near "factor at R=10, h=1.0" "$(py 'print(parent_factor(10, 1.0))')" 2.25
near "factor at R=0 is the cache write" "$(py 'print(parent_factor(0, 0.9))')" 1.25
near "factor at h=0 is the ceiling" "$(py 'print(parent_factor(10, 0.0))')" 11.25

# Sonnet: (14600*1.25*1 + 500*5) / (2.00*2.25 - 1.25*1) = 20750/3.25
near "break-even, Sonnet R=10 h=1.0" \
  "$(py 'print(breakeven_tokens("claude-sonnet-5", 10, 1.0, 14600))')" 6384.615 0.01
# Opus at the defaults: factor = 1.25 + 0.19*12 = 3.53; 20750/(5*3.53 - 1.25)
near "break-even, Opus R=12 h=0.9 (README figure)" \
  "$(py 'print(breakeven_tokens("claude-opus-5", 12, 0.9, 14600))')" 1265.244 0.01
# A Haiku parent at R=0 saves nothing: the denominator is zero.
chk "no break-even when delegating cannot pay" \
  "$(py 'print(breakeven_tokens("claude-haiku-4-5", 0, 1.0, 14600))')" None

# doctor prints the same number, from the configured floor.
out=$(SHUNT_LOG_DIR="$T/log" "$P/bin/haiku-shunt" doctor 2>&1)
chk "doctor prints the Opus break-even" \
  "$(grep -c 'claude-opus-5 .* 1,265 tokens' <<<"$out")" 1
exit $FAILED
