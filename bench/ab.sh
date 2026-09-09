#!/usr/bin/env bash
# A/B the shunt on a real task: same work, twice, measured from the transcripts.
#
#   bash bench/ab.sh --task bench/tasks/mytask.sh [--reps 5] [--model MODEL]
#
# Arms run INTERLEAVED (A,B,A,B...), never all of A then all of B: cache warmth
# and service load drift over the length of a run, and a blocked design would
# hand that drift to whichever arm went second.
#
# The metric is `haiku-shunt session-cost` -- the parent's own usage rows plus
# every subagent it spawned. No cost model, no counterfactual: both arms really
# happened. Subagents are included, or the shunt arm would look free.
#
# WARNING: between runs this resets the task repo with `git checkout . &&
# git clean -fd`, which DELETES untracked files. It refuses to start on a dirty
# repo for exactly that reason.
set -uo pipefail

# A decimal comma from the ambient locale turns "7.9" into "7,9" and silently
# shifts every column of the CSV. Found the hard way.
export LC_ALL=C

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK=""; REPS=5; MODEL=""; OUT=""; CONTROL="none"; PERM="acceptEdits"; TIMEOUT=1800
while [ $# -gt 0 ]; do
  case "$1" in
    --task)    TASK="$2"; shift 2 ;;
    --reps)    REPS="$2"; shift 2 ;;
    --model)   MODEL="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    --control) CONTROL="$2"; shift 2 ;;   # none = no plugin at all; disable = SHUNT_DISABLE=1
    --perm)    PERM="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TASK" ] && [ -f "$TASK" ] || { echo "--task FILE is required (see bench/tasks/TEMPLATE.sh)" >&2; exit 2; }

TASK_NAME=""; TASK_REPO=""; TASK_PROMPT=""
task_reset() { git -C "$TASK_REPO" checkout -- . 2>/dev/null; git -C "$TASK_REPO" clean -fdq 2>/dev/null; }
task_verify() { return 0; }
# shellcheck disable=SC1090
. "$TASK"
[ -n "$TASK_REPO" ] && [ -d "$TASK_REPO" ] || { echo "TASK_REPO is not a directory: $TASK_REPO" >&2; exit 2; }
[ -n "$TASK_PROMPT" ] || { echo "TASK_PROMPT is empty" >&2; exit 2; }

if [ -n "$(git -C "$TASK_REPO" status --porcelain 2>/dev/null)" ]; then
  echo "REFUSING: $TASK_REPO has uncommitted changes." >&2
  echo "This harness runs 'git clean -fd' between runs and would delete them." >&2
  exit 1
fi
if claude plugin list 2>/dev/null | grep -q haiku-shunt; then
  echo "WARNING: haiku-shunt looks installed as a plugin. The control arm would" >&2
  echo "         still load it. Uninstall it before benchmarking, or the arms" >&2
  echo "         are not actually different." >&2
fi

RUNDIR=$(mktemp -d "${TMPDIR:-/tmp}/shunt-ab.XXXXXX")
OUT="${OUT:-$RUNDIR/results.csv}"
echo "rep,arm,session_id,ok,wall_s,turns,parent_usd,worker_usd,total_usd,workers,denies,delegations" > "$OUT"
echo "task=$TASK_NAME repo=$TASK_REPO reps=$REPS control=$CONTROL model=${MODEL:-<default>}"
echo "results -> $OUT"

one_run() { # $1 rep  $2 arm (off|on)
  local rep="$1" arm="$2" sid logdir t0 t1 wall ok rc j denies dels
  sid=$(cat /proc/sys/kernel/random/uuid)
  logdir="$RUNDIR/log-$rep-$arm"; mkdir -p "$logdir"

  local args=(-p "$TASK_PROMPT" --session-id "$sid" --permission-mode "$PERM"
              --output-format json)
  [ -n "$MODEL" ] && args+=(--model "$MODEL")
  local envs=(SHUNT_LOG_DIR="$logdir")
  if [ "$arm" = "on" ]; then
    args+=(--plugin-dir "$PLUGIN")
  elif [ "$CONTROL" = "disable" ]; then
    args+=(--plugin-dir "$PLUGIN"); envs+=(SHUNT_DISABLE=1)
  fi

  task_reset
  t0=$(date +%s%N)
  ( cd "$TASK_REPO" && env "${envs[@]}" timeout "$TIMEOUT" claude "${args[@]}" ) \
    > "$RUNDIR/out-$rep-$arm.json" 2>"$RUNDIR/err-$rep-$arm.txt"
  rc=$?
  t1=$(date +%s%N)
  wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", (b-a)/1e9}')

  ok=0
  if [ "$rc" = "0" ] && task_verify; then ok=1; fi

  j=$("$PLUGIN/bin/haiku-shunt" session-cost "$sid" --format json 2>/dev/null) || j=""
  denies=0; dels=0
  if [ "$arm" = "on" ] && compgen -G "$logdir/events-*.jsonl" >/dev/null; then
    local r; r=$(SHUNT_LOG_DIR="$logdir" "$PLUGIN/bin/haiku-shunt" report --format json 2>/dev/null)
    denies=$(jq -r '.denies // 0' <<<"$r" 2>/dev/null || echo 0)
    dels=$(jq -r '.delegations // 0' <<<"$r" 2>/dev/null || echo 0)
  fi

  if [ -n "$j" ]; then
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$rep" "$arm" "$sid" "$ok" "$wall" \
      "$(jq -r .assistant_turns <<<"$j")" "$(jq -r .parent_usd <<<"$j")" \
      "$(jq -r .worker_usd <<<"$j")" "$(jq -r .total_usd <<<"$j")" \
      "$(jq -r '.workers|length' <<<"$j")" "$denies" "$dels" >> "$OUT"
    printf '  rep %s %-3s  ok=%s  %6ss  %3s turns  %8s  (%s denies, %s delegations)\n' \
      "$rep" "$arm" "$ok" "$wall" "$(jq -r .assistant_turns <<<"$j")" \
      "\$$(jq -r .total_usd <<<"$j")" "$denies" "$dels"
  else
    printf '%s,%s,%s,%s,%s,,,,,,%s,%s\n' "$rep" "$arm" "$sid" "$ok" "$wall" "$denies" "$dels" >> "$OUT"
    printf '  rep %s %-3s  ok=%s  %6ss  NO TRANSCRIPT (rc=%s)\n' "$rep" "$arm" "$ok" "$wall" "$rc"
  fi
}

for ((rep=1; rep<=REPS; rep++)); do
  one_run "$rep" off
  one_run "$rep" on
done
task_reset

echo
python3 - "$OUT" <<'PY'
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
def col(arm, k):
    return [float(r[k]) for r in rows if r["arm"] == arm and r[k]]
print(f"{'arm':<6}{'n':>4}{'passed':>8}{'median $':>12}{'median s':>10}{'median turns':>14}")
med = {}
for arm in ("off", "on"):
    tot, wall, turns = col(arm, "total_usd"), col(arm, "wall_s"), col(arm, "turns")
    ok = sum(1 for r in rows if r["arm"] == arm and r["ok"] == "1")
    n = sum(1 for r in rows if r["arm"] == arm)
    med[arm] = statistics.median(tot) if tot else None
    print(f"{arm:<6}{n:>4}{ok:>8}"
          f"{(f'${med[arm]:,.4f}' if tot else '-'):>12}"
          f"{(f'{statistics.median(wall):.0f}' if wall else '-'):>10}"
          f"{(f'{statistics.median(turns):.0f}' if turns else '-'):>14}")
if med["off"] and med["on"]:
    d = (med["off"] - med["on"]) / med["off"] * 100
    print(f"\nmedian delta: {d:+.1f}%  ({'shunt cheaper' if d > 0 else 'shunt MORE EXPENSIVE'})")
    print("Medians, not means: one runaway session dominates a mean of five runs.")
    fails = [r for r in rows if r["ok"] != "1"]
    if fails:
        print(f"WARNING: {len(fails)} run(s) failed the quality gate. A cheaper "
              "arm that did not do the work is not a saving.")
    if len(rows) < 6:
        print("WARNING: fewer than 3 pairs. Model nondeterminism across a long "
              "agentic task easily swamps the effect at this sample size.")
PY
echo
echo "transcripts and raw output kept in $RUNDIR"
