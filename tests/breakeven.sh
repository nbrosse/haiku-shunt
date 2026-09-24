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

# The parent writes 1h cache (2x), the worker 5m cache (1.25x).
# factor = 2 + mu*R, mu = 0.10h + 2.0(1-h): a miss re-writes the 1h cache.
near "factor at R=10, h=1.0" "$(py 'print(parent_factor(10, 1.0))')" 3.0
near "factor at R=0 is the cache write" "$(py 'print(parent_factor(0, 0.9))')" 2.0
near "factor at h=0 is the ceiling" "$(py 'print(parent_factor(10, 0.0))')" 22.0

# Sonnet: (14600*1.25*1 + 500*5) / (2.00*3.0 - 1.25*1) = 20750/4.75
near "break-even, Sonnet R=10 h=1.0" \
  "$(py 'print(breakeven_tokens("claude-sonnet-5", 10, 1.0, 14600))')" 4368.421 0.01
# Opus at the defaults: factor = 2 + 0.29*12 = 5.48; 20750/(5*5.48 - 1.25)
near "break-even, Opus R=12 h=0.9 (README figure)" \
  "$(py 'print(breakeven_tokens("claude-opus-5", 12, 0.9, 14600))')" 793.499 0.01
# Even a Haiku parent at R=0 has one: its 2x write beats the worker's 1.25x.
#   20750 / (1.00*2.0 - 1.25*1) = 27667
near "Haiku parent at R=0" \
  "$(py 'print(breakeven_tokens("claude-haiku-4-5", 0, 1.0, 14600))')" 27666.667 0.01

# Opus 5.5 reads cache at 0.05x: mu = 0.05*0.9 + 2*0.1 = 0.245, factor 4.94
#   20750 / (4*4.94 - 1.25) = 1121.016
near "break-even, Opus 5.5 (own cache-read rate)" \
  "$(py 'print(breakeven_tokens("claude-opus-5-5", 12, 0.9, 14600))')" 1121.016 0.01
# Fable 5.1 reads cache at 0.025x: mu = 0.2225, factor 4.67; 20750/(10*4.67 - 1.25)
near "break-even, Fable 5.1 (own cache-read rate)" \
  "$(py 'print(breakeven_tokens("claude-fable-5-1", 12, 0.9, 14600))')" 456.546 0.01
# A suffixed id takes the LONGEST matching prefix: Opus 5.5, not Opus 5.
near "longest prefix wins" "$(py 'print(rate("claude-opus-5-5[1m]", "input"))')" 4.0

# doctor prints the same number, from the configured floor.
out=$(SHUNT_LOG_DIR="$T/log" "$P/bin/haiku-shunt" doctor 2>&1)
chk "doctor prints the Opus break-even" \
  "$(grep -c 'claude-opus-5 .* 793 tokens' <<<"$out")" 1
chk "doctor prints the Opus 5.5 break-even" \
  "$(grep -c 'claude-opus-5-5 .* 1,121 tokens' <<<"$out")" 1
exit $FAILED
