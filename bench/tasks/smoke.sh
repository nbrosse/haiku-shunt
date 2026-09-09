#!/usr/bin/env bash
# Wiring smoke test: builds its own throwaway repo, so it touches nothing you
# care about and needs no setup.
#
# This is NOT a benchmark. One short task means R is near zero, so the cost
# comparison between arms is meaningless and will probably favour the control.
# It exists to prove the chain -- hook fires, denies, delegates, logs, prices --
# before you spend real money on a task worth measuring.

TASK_NAME="smoke-self"
TASK_REPO="${TMPDIR:-/tmp}/shunt-smoke-repo"

if [ ! -f "$TASK_REPO/service.py" ]; then
  mkdir -p "$TASK_REPO"
  python3 - "$TASK_REPO/service.py" <<'PY'
import sys
out = ["import time, random, logging\n\nlog = logging.getLogger(__name__)\n\n"]
for i in range(60):
    out.append(f'''
class Handler{i:02d}:
    """Handles category {i} events with a retry policy."""

    MAX_ATTEMPTS = {3 + i % 4}
    BASE_DELAY = {0.1 * (i % 5 + 1):.2f}

    def __init__(self, transport, clock=time):
        self.transport = transport
        self.clock = clock

    def backoff_delay_{i:02d}(self, attempt):
        """Exponential backoff with full jitter for category {i}."""
        return random.uniform(0, self.BASE_DELAY * (2 ** attempt))

    def dispatch(self, payload):
        for attempt in range(self.MAX_ATTEMPTS):
            try:
                return self.transport.send(payload)
            except TimeoutError:
                self.clock.sleep(self.backoff_delay_{i:02d}(attempt))
        raise RuntimeError("category {i} exhausted retries")
''')
open(sys.argv[1], "w").write("".join(out))
PY
  ( cd "$TASK_REPO" && git init -q . && git add -A && git commit -qm fixture )
fi

TASK_PROMPT="Read service.py and answer both: (1) which Handler classes have
MAX_ATTEMPTS equal to 6, and (2) what BASE_DELAY does Handler37 use? Use the
Read tool, not grep or shell commands."

task_reset() { git -C "$TASK_REPO" checkout -- . 2>/dev/null; git -C "$TASK_REPO" clean -fdq 2>/dev/null; }

# Handler37: MAX_ATTEMPTS = 3 + 37%4 = 4, BASE_DELAY = 0.1 * (37%5 + 1) = 0.30.
# The gate is the answer, not the plumbing: a shunt that saves tokens by
# getting the question wrong has saved nothing.
task_verify() { grep -qE '0\.30|0\.3\b' "$RUNDIR/out-$rep-$arm.json" 2>/dev/null; }
