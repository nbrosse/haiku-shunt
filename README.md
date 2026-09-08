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

Piped, redirected and heredoc commands are allowed: their output does not reach
the model. So are `grep`, `sed`, `awk`, `git show` and `python -c open(...)` —
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
  break-even file size at these settings: 1,470 tokens (~113 lines)
  3/14 denies were BELOW break-even - raise SHUNT_MIN_LINES
```

The default 350 lines suits an Opus parent. On Sonnet, break-even is higher —
run `haiku-shunt doctor`, which computes it from your own delegations and tells
you what to set.

## Commands

```bash
haiku-shunt report [--parent MODEL] [--turns N] [--cache-hit 0..1] [--since DAYS]
                   [--worker-floor N] [--format table|json]
haiku-shunt analyze [TRANSCRIPT] [--all] [--write]   # measured, not modelled
haiku-shunt doctor                                   # install + assumptions
```

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

- `bash -c "cat big.txt"` is not inspected.
- Token estimates are `chars/4`, ±15% on source code. Only `T` is estimated;
  worker cost and turns-remaining are measured.
- The counterfactual — whether you would have read the file at all — is not
  observable. **The parent-side saving is a model, not a measurement**, and the
  report says so every time it prints.
- Delegation adds seconds of latency to a large read. `SHUNT_MODE=warn` is the
  gentler setting for interactive work.
- `claude plugin validate` does **not** check agent frontmatter — it accepts a
  nonexistent `model:`. Only `haiku-shunt analyze` proves the worker is on Haiku.

## Development

```bash
bash evals/run.sh              # 173 offline cases: hooks, recursion, robustness, cost math
bash evals/run.sh -v --hook bash --filter head
claude plugin validate --strict .
```

No network, no API cost, no Claude Code required. The suite covers the shell
parser hard (bounded reads, fd-aware redirects, heredocs, `cd` tracking,
prefixes, quoting, `/dev/zero`, symlinks), the recursion guards including the
namespaced form, fail-open on malformed input, 200-way concurrent log appends,
and the cost arithmetic against hand-computed values.

`claude plugin eval` cases would be the natural second tier for behavioural
checks, but it is early-access gated and cannot assert hook decisions anyway.

## Credit

The idea is Spotify's — see [NOTICE](NOTICE). This is an independent
implementation with a different worker transport; no Spotify code is copied.

Apache-2.0.
