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

Three things this repo does that a headline percentage cannot:

**It measures the worker instead of assuming it.** Every subagent writes its own
transcript, and `agent-<id>.meta.json` links it back to the parent's `Task`
call. `haiku-shunt analyze` reads them and reports what the worker actually
cost. Aggregating that usage has a trap: Claude Code writes one row per content
block and repeats the message's usage on each, so summing rows overcounts ~3×,
while taking the first row per message undercounts output ~60× (`output_tokens`
grows across blocks; the input side does not). See `hooks/lib/usage.jq`.

Three of the model's inputs start as assumptions and get replaced by
measurements as soon as there is something to measure:

| input | assumed | measured from |
|---|---|---|
| worker cache-write floor | 14,600 tok | median of your own delegations |
| summary size | 300 tok | the worker's last message (`final_output_tokens`) |
| `R`, turns remaining | 12 | parent turns after the delegation, via `analyze --write` |

The report header says which one it used — `R=7 (measured from 2 delegation(s))`
or `R=12 (assumed)` — so a number you are about to trust never hides its
provenance.

**It accounts for `Read`'s truncation.** `Read` stops at ~2000 lines, so a
4014-line file never costs the parent 4014 lines. Whole-file numbers overstate
the saving. The report shows the capped figure as the headline and the uncapped
one beside it, so you can see the difference.

**It prints a break-even.** A subagent has a fixed cost before it reads
anything — a system-prompt cache write, measured per installation rather than
assumed. Below that size, delegating *loses* money:

```
haiku-shunt report --parent claude-opus-5
...
  break-even file size at these settings: 1,265 tokens (~97 lines)
  3/14 denies were BELOW break-even - raise SHUNT_MIN_LINES
```

(1,265 is the figure for the default 14,600-token floor at `R=12`; `doctor`
prints the same number. Once your own delegations have been measured, the floor
— and this threshold — move.)

The default 350 lines suits an Opus parent. On Sonnet, break-even is higher —
run `haiku-shunt doctor`, which computes it from your own delegations and tells
you what to set.

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
symmetry that does not exist. What the plugin does do is **measure it**:
`SubagentStop` matches `code-writer` too, and the report gives it its own
section, valuing the tokens the worker generated at the parent's output rate
plus the context they never entered.

That figure is labelled `proxy`, not `estimated` or `MEASURED`, because the
worker's output stands in for output the parent never produced. There is no
counterfactual to compare against — the same honesty problem as the read side,
one step further from the evidence.

## Commands

```bash
haiku-shunt report [--parent MODEL] [--turns N] [--cache-hit 0..1] [--since DAYS]
                   [--worker-floor N] [--format table|json]
haiku-shunt analyze [TRANSCRIPT] [--all] [--write]   # measured, not modelled
                                                     # --write also feeds R back
haiku-shunt session-cost [TRANSCRIPT|SESSION_ID]     # parent + subagents, no model
haiku-shunt doctor                                   # install + assumptions
```

`session-cost` is the only number here with no cost model behind it: it prices
a whole session from the transcripts\' own usage rows, parent plus every
subagent it spawned. That makes it the metric for an A/B — run the same task
with and without the shunt and compare two things that both really happened,
instead of one that happened and one that was modelled.

## Benchmarking

```bash
bash bench/ab.sh --task bench/tasks/smoke.sh --reps 1   # prove the wiring
bash bench/ab.sh --task bench/tasks/mytask.sh --reps 5  # a real measurement
```

Arms run interleaved (A,B,A,B…) because cache warmth and service load drift
over a run; the control arm loads no plugin at all, so the comparison is not
confounded by the agents still being available. Each run gets a fresh session
id and its own log dir, and every row carries a pass/fail from the task\'s own
`task_verify` — a cheaper arm that did not do the work is not a saving.

**The task must be long and multi-turn, and must read the big files early.**
The entire thesis is that context is re-sent on every later turn, so a one-shot
"read this and summarise it" measures the 1.25× cache write and nothing else.
`bench/tasks/smoke.sh` is deliberately that shape, and it reliably shows the
shunt losing — it is there to prove the chain fires, not to measure anything.
See `bench/tasks/TEMPLATE.sh`.

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

Prices live in `config/defaults.json` too. **Check them before trusting the
money column** — they change, and this file is the only place they are stated.

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

- **After a deny, the model reliably picks windowed reads over delegating.**
  In every unprompted live run so far it chose option 2, never option 1 — so
  the tokens are avoided by paging rather than by a subagent. The report still
  credits the deny with the whole file, which overstates the saving by whatever
  the windows brought back in. Delegation happens when asked for by name.
- The measured worker cost used to race the transcript: `SubagentStop` fires
  while the worker\'s final message is still being flushed, and reading too
  early undercounted its output ~6×. `hooks/subagent-stop.sh` now waits for the
  final text block; records carry `transcript_settled` so you can see when it
  gave up waiting.
- `bash -c "cat big.txt"` is not inspected.
- Token estimates are `chars/4`, ±15% on source code. `T` is estimated; worker
  cost, summary size and turns-remaining are measured (`R` only after
  `analyze --write`; until then the report says `assumed`).
- The `code-writer` saving is a proxy, not a measurement — see above.
- The counterfactual — whether you would have read the file at all — is not
  observable. **The parent-side saving is a model, not a measurement**, and the
  report says so every time it prints.
- Delegation adds seconds of latency to a large read. `SHUNT_MODE=warn` is the
  gentler setting for interactive work.
- `claude plugin validate` does **not** check agent frontmatter — it accepts a
  nonexistent `model:`. Only `haiku-shunt analyze` proves the worker is on Haiku.

## Development

```bash
bash evals/run.sh              # 220 offline cases: hooks, recursion, robustness, cost math
bash evals/run.sh -v --hook bash --filter head
claude plugin validate --strict .
```

No network, no API cost, no Claude Code required. The suite covers the shell
parser hard (bounded reads, fd-aware redirects, heredocs, `cd` tracking,
prefixes, quoting, `/dev/zero`, symlinks), the recursion guards including the
namespaced form, fail-open on malformed input, 200-way concurrent log appends,
and the cost arithmetic against hand-computed values — including the write-side
proxy, the measured-vs-assumed provenance of `R`, the fact that `group_by`
sorts by `message.id` so the last group is not the last message, and the
SubagentStop race below.

`claude plugin eval` cases would be the natural second tier for behavioural
checks, but it is early-access gated and cannot assert hook decisions anyway.

## Credit

The idea is Spotify's — see [NOTICE](NOTICE). This is an independent
implementation with a different worker transport; no Spotify code is copied.

Apache-2.0.
