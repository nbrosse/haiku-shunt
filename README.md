# haiku-shunt

Keeps bulk file reads out of your orchestrator's context by delegating them to
a Haiku subagent. A Portal-free reimplementation of
[Spotify's `shunt`](https://github.com/spotify/portal-ai-plugins/tree/main/plugins/shunt).

```
              Sonnet / Opus  (reasoning, debugging, edits)
                     │
               PreToolUse hook
       ┌─────────────┴──────────────┐
 windowed / small                 bulk
 Read(offset, limit)         Read(4000-line file)
 head -20 f, grep, pipes     cat f, less f
       │                            │
     allow                   permissionDecision: "deny"
                                    │  the reason tells the model what to do instead
                                    ▼
                     Task(subagent_type="bulk-reader")
                           model: claude-haiku-4-5
                           tools: Read, Grep, Glob
                                    │
                          reads in ITS OWN context
                                    │
                            ~300-token answer
                                    ▼
                            Sonnet / Opus continues
```

Spotify's version routes the worker through `portal-cli` → Spotify Portal/AiKA
→ Gemini Flash, so cloning their repo does not give you a working backend. Here
the worker is a native Claude Code subagent. There is no service to sign up
for, no API key, and no transport layer: context isolation is already what a
subagent *is*.

## Install

```bash
git clone https://github.com/nbrosse/haiku-shunt
claude plugin marketplace add ./haiku-shunt
claude plugin install haiku-shunt@haiku-shunt
```

Or, to try it without installing:

```bash
claude --plugin-dir ./haiku-shunt
```

Then read a file over 350 lines and watch what happens.

## What it does

**Read hook.** Denies a full-file `Read` when the file is over `SHUNT_MIN_LINES`
(350) *and* over `SHUNT_MIN_BYTES` (8000), or over `SHUNT_MAX_BYTES` (200 KB)
regardless of line count — a minified 2 MB bundle is one line and would sail
past a line-only threshold. A `Read` with `offset`/`limit` is always allowed: it
is what we tell the model to do after a deny, and it is what editing requires.

**Bash hook.** Catches `cat`/`less`/`more`/`bat` dumps that bypass the Read
tool. It treats a *bounded* read as equivalent to `Read(limit=N)`, which is
where it differs from upstream:

| command | haiku-shunt | Spotify's shunt |
|---|---|---|
| `head -100 big.txt` | allow — 100 lines is a windowed read | block |
| `head -n 5 big.txt` | allow — bounded | allow, but by accident: their flag-stripper takes `5` as the filename |
| `head -n 5000 big.txt` | deny — bounded but still the whole file | block |
| `tail -n +4900 huge.txt` | allow — only 101 of 5000 lines | block |
| `cat f 2>/dev/null` | deny — only stderr is redirected; stdout still reaches the model | allow |
| `cd sub && cat big.txt` | deny — `cd` is tracked | allow |
| `head -5 small.txt; cat big.txt` | deny — every segment is checked | allow |
| `cat big.txt \| cat` | deny — a copy is not a filter | allow |
| `cat big.txt \| grep x` | allow — filtered | allow |

Every segment of a command is checked. A read whose stdout is redirected, or
piped into a filter (`grep`, `wc`, `sort`, …), is allowed: the file does not
reach the model. A pipe through a copy (`| cat`, `| tee f`, `| less`) does, so
it is checked like the bare read; `| head -N` caps it at N lines. Heredocs are
allowed. So are `grep`, `sed`, `awk`, `git show` and `python -c open(...)` —
see [Non-goals](#non-goals).

**Fail-open is the invariant.** Malformed input, an unparseable command, a
missing `jq`, an internal error — all emit nothing and exit 0. A broken shunt
must never be able to wedge a session. The allow path emits *no* decision at
all, rather than `permissionDecision: "allow"`, which would override your own
permission rules.

## What it actually saves

Rate arbitrage is the small part: Haiku 4.5 ($1/$5 per MTok) against Sonnet 5
($2/$10) is 2×, not 10×. The real win is that **parent context is re-sent on
every subsequent turn**. A 30K-token file read on turn 3 of a 40-turn session is
re-sent ~37 more times, discounted to ~10% of the input rate by prompt caching.
Keeping it out of the parent entirely is what compounds.

```
C_avoided = T · P_in · (1.25 + μ·R) / 1e6      μ = 0.10h + 1.0(1−h)
```

`T` = tokens in the file, `R` = turns remaining after the read, `h` = cache-hit
rate. At `R=0` this collapses to the naive "file tokens × parent rate". The
`μ·R` term is where the saving lives.

That formula is the argument, not the measurement. Whether you would have read
the file at all is not observable, so no log of what the hooks did can say what
they saved. **The only number this repo trusts is an A/B**: the same task with
and without the plugin, priced by Claude Code itself (see
[Benchmarking](#benchmarking)).

**Break-even.** A subagent has a fixed cost before it reads anything — a
system-prompt cache write, ~14,600 tokens. Below some file size, delegating
*loses* money. `haiku-shunt doctor` prints that size from the formula and the
prices in `config/defaults.json`:

```
break-even vs claude-sonnet-5       3,571 tokens  (~  275 lines)
break-even vs claude-opus-5         1,265 tokens  (~   97 lines)
```

It is an order of magnitude, from assumed `R=12` and `h=0.9`, and it needs no
data. The default 350 lines suits an Opus parent and sits just above
break-even on Sonnet.

## The other direction: `code-writer`

`bulk-reader` keeps tokens out of the *input* side. `code-writer` keeps them off
the *output* side: give it a spec and a reference file and it writes the target
to disk on Haiku, returning ten lines instead of the file. For generated tests,
fixtures, config and type stubs — where most of the output is predictable from
a file that already exists — that is the expensive direction, at 5× the input
rate.

**There is no Write hook, and there cannot be one.** `PreToolUse` fires after
the model has produced `tool_input.content`; the output tokens are already
spent by the time a hook could object. Denying the `Write` and asking for a
subagent then pays for the same code twice. Reads can be intercepted because
the cost lands *after* the tool call; writes cannot, because it lands before.

So this half is a choice the model makes up front, from the agent description,
not a rule the plugin enforces — and the README says so rather than implying a
symmetry that does not exist. Whether it pays off is, again, an A/B question.

## Commands

```bash
haiku-shunt report [--since DAYS] [--format table|json]   # what the hooks did
haiku-shunt doctor                                        # install + break-even
```

`report` only counts: how often each hook fired, why (including
`deny_cap_reached`, a large file that got through anyway), and how big the
denied files were — lines that would have reached the model, in buckets. The
buckets say how many denies a different threshold would change, which is how
you pick the values worth benchmarking.

## Benchmarking

```bash
bash bench/ab.sh --task bench/tasks/smoke.sh --reps 1   # prove the wiring
bash bench/ab.sh --task bench/tasks/mytask.sh --reps 5  # a real measurement
bash bench/ab.sh --task bench/tasks/mytask.sh --reps 5 \
  --arm min200:SHUNT_MIN_LINES=200 --arm min800:SHUNT_MIN_LINES=800
```

Each run is a `claude -p --output-format json`, and the cost is what Claude
Code reports: `total_cost_usd`, with `modelUsage` broken down per model —
subagents included, or the shunt arm would look free. That figure prices cache
writes at the TTL actually used (1-hour writes are 2× input, not 1.25×), which
a hand-rolled price table gets wrong. The CSV also records turns, wall time,
Haiku spend (workers plus ~$0.001 of Claude Code's own background Haiku call,
present in the control arm too), denies and delegations per run.

The control arm `off` loads no plugin at all, so the comparison is not
confounded by the agents still being available. Without `--arm` the other arm
is `on` (plugin defaults); with `--arm`, one arm per flag, each with its own
environment. Arms run interleaved, in an order that rotates every rep, because
cache warmth and service load drift over a run. Every row carries a pass/fail
from the task's own `task_verify` — a cheaper arm that did not do the work is
not a saving.

**The task must be long and multi-turn, and must read the big files early.**
The entire thesis is that context is re-sent on every later turn, so a one-shot
"read this and summarise it" measures the cache write and nothing else.
`bench/tasks/smoke.sh` is deliberately that shape, and it reliably shows the
shunt losing — it is there to prove the chain fires, not to measure anything.
See `bench/tasks/TEMPLATE.sh`.

**Tuning the threshold** is coarse by necessity. Two agentic sessions on the
same task easily differ by 20–40% in cost, so 350 vs 450 lines is not
measurable in any affordable number of runs; 200 vs 350 vs 800 can be. Start
from `doctor`'s break-even, look at `report`'s size buckets to see which values
would change anything, and A/B only those.

Also `/haiku-shunt:shunt-report` and `/haiku-shunt:shunt-doctor` inside a session.

## Configuration

Everything in `config/defaults.json`, overridable by environment variable:

| variable | default | meaning |
|---|---|---|
| `SHUNT_MIN_LINES` | 350 | line threshold |
| `SHUNT_MIN_BYTES` | 8000 | byte floor: never shunt a small file, however many lines |
| `SHUNT_MAX_BYTES` | 200000 | byte ceiling: shunt regardless of line count |
| `SHUNT_MODE` | `deny` | `warn` nudges via `additionalContext` instead of denying |
| `SHUNT_MAX_DENIES_PER_PATH` | 2 | after this, the same path in the same session is let through |
| `SHUNT_SHUNT_OTHER_AGENTS` | 1 | also shunt non-worker subagents (Explore, Plan…) |
| `SHUNT_DISABLE` | — | `1` turns everything off |
| `SHUNT_LOG_DIR` | plugin data dir | where `events-*.jsonl` goes |
| `SHUNT_LOG_LOCK` | 0 | `1` adds `flock`; set this on NFS/CIFS |

Prices live in `config/defaults.json` too, used only for `doctor`'s
break-even. They change; benchmark costs come from Claude Code, not from here.

## How it avoids deadlocking on itself

If the hook denied the worker's own reads, every large file would wedge. Three
independent guards, because the first one is not guaranteed:

1. **`agent_type`.** Allowed when the calling agent is one of ours. Plugin
   agents arrive **namespaced** — `haiku-shunt:bulk-reader`, not `bulk-reader` —
   so the comparison is on the base name. This was found by running it, not by
   reading docs, and getting it wrong cost the worker three extra turns.
2. **Non-worker subagents** are still shunted by default (they benefit too);
   `SHUNT_SHUNT_OTHER_AGENTS=0` exempts them.
3. **The deny cap.** After `SHUNT_MAX_DENIES_PER_PATH` refusals of the same path
   in the same session, it is let through. This makes a loop structurally
   impossible whatever happens to `agent_type` in a future release, and it is
   why the deny message can honestly promise the model a way out.

## Non-goals

`grep -A 99999`, `sed`, `awk`, `git show`, `python -c "print(open(f).read())"`
all still work. Blocking them would break the tools the model *should* be
reaching for, and each addition makes fail-open more fragile.

**haiku-shunt makes the cheap path the default path. It does not prevent a
determined model from reading a file.** Rather than assume the guidance works,
the report counts how often a large file reached context anyway, so evasion is
visible.

## Known limits

- **After a deny, the model reliably picks windowed reads over delegating**, or
  retries the full read until the deny cap lets it through. In every unprompted
  live run so far it never chose option 1 — delegation happens when asked for
  by name. Only an A/B says whether the denies still pay for themselves.
- `bash -c "cat big.txt"` is not inspected.
- Token estimates in the log are `chars/4`, ±15% on source code. They feed
  nothing but the size buckets.
- The break-even is a formula with assumed `R` and `h`, not a measurement.
- Delegation adds seconds of latency to a large read. `SHUNT_MODE=warn` is the
  gentler setting for interactive work.
- `claude plugin validate` does **not** check agent frontmatter — it accepts a
  nonexistent `model:`. After a delegation, `message.model` in the worker's
  transcript (`~/.claude/projects/<project>/<session>/subagents/agent-*.jsonl`)
  proves it is on Haiku. A Haiku entry in `modelUsage` does not: Claude Code
  makes a small Haiku call of its own in every session.

## Development

```bash
bash evals/run.sh              # offline cases: hooks, recursion, robustness, report
bash evals/run.sh -v --hook bash --filter head
claude plugin validate --strict .
```

No network, no API cost, no Claude Code required. The suite covers the shell
parser hard (bounded reads, fd-aware redirects, heredocs, `cd` tracking,
prefixes, quoting, pipelines, `/dev/zero`, symlinks), the recursion guards
including the namespaced form, fail-open on malformed input, 200-way concurrent
log appends, the deny cap, the report's counts and size buckets, and the
break-even arithmetic against hand-computed values.

`claude plugin eval` cases would be the natural second tier for behavioural
checks, but it is early-access gated and cannot assert hook decisions anyway.

## Credit

The idea is Spotify's — see [NOTICE](NOTICE). This is an independent
implementation with a different worker transport; no Spotify code is copied.

Apache-2.0.
