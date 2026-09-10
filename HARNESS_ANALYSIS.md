# Harness Analysis

The harness is well-structured and unusually thoughtful about fail-open
behavior, recursion prevention, transcript races, and cost provenance.
However, the review found four substantive correctness issues.

## Findings

### 1. High: Bash guard misses later or pass-through reads

`hooks/lib/bashparse.py:287` exits on the first reader segment, including
segments classified as safe at lines 311–318.

Confirmed false negatives:

```bash
cat big.txt >/dev/null; cat big.txt
head -5 small.txt; cat big.txt
cat big.txt | cat
```

These respectively return `redirected`, inspect only `small.txt`, and return
`piped`. In all three cases, the large file ultimately reaches stdout. This
also makes the README claim that piped commands do not reach the model too
broad.

The parser needs to evaluate all command segments and, for pipelines,
determine what the final stdout-producing stage emits, rather than treating
the first safe reader as an overall allow.

### 2. High: Measured remaining-turn count is not deduplicated

`bin/haiku-shunt:423` says assistant turns are deduplicated, but appends every
assistant transcript row and counts them at line 452. Since the harness
correctly recognizes elsewhere that Claude Code can write multiple rows per
message, one turn can be counted several times.

This inflates `R`, which directly inflates gross and net estimated savings.
The same issue affects the displayed `assistant_turns` at line 347.

The existing session-cost test codifies the defect: two distinct message IDs
represented by three rows are expected to equal three turns. Turns should be
deduplicated by `message.id`, with a fallback for rows lacking an ID.

### 3. Medium: Report undercounts deny-message overhead

At `bin/haiku-shunt:187-189`, deny overhead is charged once per read
delegation whenever any delegation exists, rather than once per denial.

The README says models usually respond to a denial with windowed reads rather
than delegation. Therefore, a realistic session with ten denies and one
delegation charges only one deny reason, overstating net savings.

Conceptually, overhead should be:

```text
deny reasons * all denies
+ prompt/summary * delegations
```

### 4. Medium: SubagentStop violates the fail-open invariant for valid non-object JSON

`hooks/subagent-stop.sh:12` validates only that input is JSON. Unlike the Read
and Bash hooks, it does not normalize non-object payloads before indexing
fields.

Confirmed behavior:

```text
input: []
exit: 1
error: Cannot index array ... followed by an unbound AGENT_TYPE
```

This contradicts the stated invariant that malformed input and internal
errors always exit zero. The robustness suite covers array payloads for the
two guards, but not `SubagentStop`.

## Verification

- Shell and Python syntax checks passed.
- The full offline suite passed: **203 passed, 0 failed**.
- Additional targeted probes reproduced the Bash-parser and SubagentStop
  failures.
- `shellcheck` was unavailable.
- No existing repository files were changed during the analysis.

## Overall assessment

The hook thresholding and accounting machinery are carefully engineered, but
the Bash parser's single-result design and the turn-count inflation materially
weaken the harness's central claims. The Bash parser and measured `R` should be
addressed first because they affect whether content is intercepted and whether
the reported savings can be trusted.
