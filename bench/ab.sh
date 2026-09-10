#!/usr/bin/env bash
# A/B the shunt on a real task: same work, several times, priced by Claude Code.
#
#   bash bench/ab.sh --task bench/tasks/mytask.sh [--reps 5] [--model MODEL]
#                    [--arm NAME:VAR=VAL[,VAR=VAL]]...
#
# Arms: `off` (control, always present) plus either `on` (the plugin with its
# defaults) or one arm per --arm, each loading the plugin with its own env:
#
#   --arm min200:SHUNT_MIN_LINES=200 --arm min800:SHUNT_MIN_LINES=800
#
# Arms run INTERLEAVED, never all of A then all of B: cache warmth and service
# load drift over the length of a run, and a blocked design would hand that
# drift to whichever arm went last. The order rotates each rep so no arm is
# always first.
#
# The metric is what Claude Code itself reports in `--output-format json`:
# total_cost_usd, with modelUsage broken down per model -- subagents included,
# or the shunt arm would look free. No cost model, no counterfactual: every arm
# really happened.
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
ARM_NAMES=(off); ARM_ENVS=("")
while [ $# -gt 0 ]; do
  case "$1" in
    --task)    TASK="$2"; shift 2 ;;
    --reps)    REPS="$2"; shift 2 ;;
    --model)   MODEL="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    --control) CONTROL="$2"; shift 2 ;;   # none = no plugin at all; disable = SHUNT_DISABLE=1
    --perm)    PERM="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --arm)
      name="${2%%:*}"; envs=""; [ "$name" != "$2" ] && envs="${2#*:}"
      case "$name" in ''|off|*,*) echo "bad --arm name: '$name'" >&2; exit 2 ;; esac
      ARM_NAMES+=("$name"); ARM_ENVS+=("$envs"); shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
[ "${#ARM_NAMES[@]}" -eq 1 ] && { ARM_NAMES+=(on); ARM_ENVS+=(""); }
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
echo "rep,arm,session_id,ok,wall_s,turns,total_usd,haiku_usd,denies,delegations" > "$OUT"
echo "task=$TASK_NAME repo=$TASK_REPO reps=$REPS arms=${ARM_NAMES[*]} control=$CONTROL model=${MODEL:-<default>}"
echo "results -> $OUT"

# Delegations to our workers, counted from the subagent metadata Claude Code
# writes next to the session transcript. Plugin agents are namespaced
# ("haiku-shunt:bulk-reader"), so compare the base name.
count_delegations() { # $1 session id
  local m n=0
  for m in "$HOME"/.claude/projects/*/"$1"/subagents/agent-*.meta.json; do
    [ -f "$m" ] || continue
    case "$(jq -r '.agentType // ""' "$m" 2>/dev/null)" in
      bulk-reader|code-writer|*:bulk-reader|*:code-writer) n=$((n + 1)) ;;
    esac
  done
  printf '%s' "$n"
}

one_run() { # $1 rep  $2 arm index
  local rep="$1" name="${ARM_NAMES[$2]}" arm_env="${ARM_ENVS[$2]}"
  local sid logdir t0 wall ok rc out stats total turns haiku denies dels
  sid=$(cat /proc/sys/kernel/random/uuid)
  logdir="$RUNDIR/log-$rep-$name"; mkdir -p "$logdir"
  out="$RUNDIR/out-$rep-$name.json"

  local args=(-p "$TASK_PROMPT" --session-id "$sid" --permission-mode "$PERM"
              --output-format json)
  [ -n "$MODEL" ] && args+=(--model "$MODEL")
  local envs=(SHUNT_LOG_DIR="$logdir") plugin=0
  if [ "$name" != "off" ]; then
    args+=(--plugin-dir "$PLUGIN"); plugin=1
    [ -n "$arm_env" ] && IFS=',' read -ra extra <<<"$arm_env" && envs+=("${extra[@]}")
  elif [ "$CONTROL" = "disable" ]; then
    args+=(--plugin-dir "$PLUGIN"); envs+=(SHUNT_DISABLE=1)
  fi

  task_reset
  t0=$(date +%s%N)
  ( cd "$TASK_REPO" && env "${envs[@]}" timeout "$TIMEOUT" claude "${args[@]}" ) \
    > "$out" 2>"$RUNDIR/err-$rep-$name.txt"
  rc=$?
  wall=$(awk -v a="$t0" -v b="$(date +%s%N)" 'BEGIN{printf "%.1f", (b-a)/1e9}')

  ok=0
  arm="$name"   # task_verify reads $rep and $arm
  if [ "$rc" = "0" ] && task_verify; then ok=1; fi

  # haiku_usd is every Haiku call in the session: our workers, plus a small
  # background call Claude Code makes on its own (~$0.001, present in the
  # control arm too). Meaningless if the parent itself runs on Haiku.
  # total_cost_usd prices cache writes at the TTL actually used (1h = 2x input),
  # which a hand-rolled 1.25x would undercount by ~1/3 on a short session.
  stats=$(jq -r '[(.total_cost_usd // ([.modelUsage[]?.costUSD] | add) // ""),
                  (.num_turns // ""),
                  ([(.modelUsage // {}) | to_entries[] | select(.key | test("haiku"))
                    | .value.costUSD] | add // 0)] | @tsv' "$out" 2>/dev/null) || stats=""
  IFS=$'\t' read -r total turns haiku <<<"$stats"

  denies=0
  if [ "$plugin" = "1" ] && compgen -G "$logdir/events-*.jsonl" >/dev/null; then
    denies=$(SHUNT_LOG_DIR="$logdir" "$PLUGIN/bin/haiku-shunt" report --format json 2>/dev/null \
             | jq -r '.denies // 0' 2>/dev/null) || denies=0
  fi
  dels=$(count_delegations "$sid")

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$rep" "$name" "$sid" "$ok" "$wall" \
    "${turns:-}" "${total:-}" "${haiku:-}" "${denies:-0}" "$dels" >> "$OUT"
  if [ -n "${total:-}" ]; then
    printf '  rep %s %-8s ok=%s  %6ss  %3s turns  $%-10s (%s denies, %s delegations)\n' \
      "$rep" "$name" "$ok" "$wall" "${turns:-?}" "$total" "${denies:-0}" "$dels"
  else
    printf '  rep %s %-8s ok=%s  %6ss  NO COST IN OUTPUT (rc=%s, see %s)\n' \
      "$rep" "$name" "$ok" "$wall" "$rc" "$out"
  fi
}

N_ARMS=${#ARM_NAMES[@]}
for ((rep=1; rep<=REPS; rep++)); do
  for ((k=0; k<N_ARMS; k++)); do
    one_run "$rep" $(( (k + rep - 1) % N_ARMS ))
  done
done
task_reset

echo
python3 - "$OUT" "${ARM_NAMES[@]}" <<'PY'
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
arms = sys.argv[2:]
def col(arm, k):
    return [float(r[k]) for r in rows if r["arm"] == arm and r[k]]
print(f"{'arm':<10}{'n':>4}{'passed':>8}{'median $':>12}{'vs off':>9}"
      f"{'median s':>10}{'turns':>7}{'denies':>8}{'deleg':>7}")
med = {}
for arm in arms:
    tot = col(arm, "total_usd")
    med[arm] = statistics.median(tot) if tot else None
for arm in arms:
    n = sum(1 for r in rows if r["arm"] == arm)
    ok = sum(1 for r in rows if r["arm"] == arm and r["ok"] == "1")
    wall, turns = col(arm, "wall_s"), col(arm, "turns")
    den, dels = col(arm, "denies"), col(arm, "delegations")
    delta = "-"
    if arm != "off" and med[arm] and med.get("off"):
        delta = f"{(med[arm] - med['off']) / med['off'] * 100:+.1f}%"
    m = lambda xs, f="{:.0f}": f.format(statistics.median(xs)) if xs else "-"
    print(f"{arm:<10}{n:>4}{ok:>8}"
          f"{(f'${med[arm]:,.4f}' if med[arm] is not None else '-'):>12}{delta:>9}"
          f"{m(wall):>10}{m(turns):>7}{m(den):>8}{m(dels):>7}")
print("\nvs off: negative = cheaper than the control. Medians, not means: one")
print("runaway session dominates a mean of five runs.")
fails = [r for r in rows if r["ok"] != "1"]
if fails:
    print(f"WARNING: {len(fails)} run(s) failed the quality gate. A cheaper "
          "arm that did not do the work is not a saving.")
if min(sum(1 for r in rows if r["arm"] == a) for a in arms) < 3:
    print("WARNING: fewer than 3 runs per arm. Model nondeterminism across a long "
          "agentic task easily swamps the effect at this sample size.")
PY
echo
echo "transcripts and raw output kept in $RUNDIR"
