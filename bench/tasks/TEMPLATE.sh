#!/usr/bin/env bash
# A benchmark task. Sourced by bench/ab.sh -- set the variables, override the
# two functions if the defaults do not fit.
#
# THE ONE RULE: the task must be LONG and MULTI-TURN, and it must read the big
# files EARLY. The shunt's whole thesis is that context is re-sent on every
# later turn, so a one-shot "read this file and summarise it" measures the
# cache write and nothing else -- it will tell you the shunt does
# nothing, and the benchmark will be what is wrong. Aim for 20+ turns.

TASK_NAME="rename-and-test"

# Must be a clean git repo: the harness resets it between runs.
TASK_REPO="$HOME/PycharmProjects/your-project"

# Long, specific, and verifiable. Force real work after the reading.
TASK_PROMPT="Read src/core/engine.py and src/core/scheduler.py to understand how
retries are wired. Then add exponential backoff with jitter to the retry path,
update the existing tests to cover it, and run the test suite until it passes.
Do not stop until the tests are green."

# Return to the starting state. The default is usually right; override if the
# task writes outside the repo or needs a venv rebuilt.
# task_reset() { git -C "$TASK_REPO" checkout -- .; git -C "$TASK_REPO" clean -fdq; }

# The quality gate. Return 0 only if the work was ACTUALLY done -- a cheaper
# session that failed the task is not a saving, and without this the benchmark
# rewards giving up early.
task_verify() {
  ( cd "$TASK_REPO" && python -m pytest -q >/dev/null 2>&1 )
}
