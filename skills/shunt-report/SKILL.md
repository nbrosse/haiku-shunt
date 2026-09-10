---
name: shunt-report
description: Show what haiku-shunt's hooks have done - how often they fired and denied, why, and how big the denied files were. Use when the user asks whether the shunt is firing, how often a large file got through anyway, or which threshold values are worth benchmarking.
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/haiku-shunt:*)
---

Run the report and present it:

```!
${CLAUDE_PLUGIN_ROOT}/bin/haiku-shunt report $ARGUMENTS
```

Then, briefly:

- Lead with the deny rate and the most common reasons.
- Point out `deny_cap_reached`: each one is a large file that reached context
  anyway after the model retried.
- Read the DENIED SIZES buckets: a threshold change only affects denies in the
  buckets it crosses. If almost none sit near the threshold, tuning it will
  not change anything.
- This report does not say what the shunt saved, and must not be presented as
  if it did. Cost is measured only by A/B - same task with and without the
  plugin, priced by Claude Code: `bash ${CLAUDE_PLUGIN_ROOT}/bench/ab.sh`, with
  `--arm NAME:SHUNT_MIN_LINES=N` to compare thresholds.

Useful flags: `--since DAYS`, `--format json`.
