---
name: shunt-report
description: Show what haiku-shunt has actually saved - delegations, tokens kept out of context, measured worker cost, and net saving. Use when the user asks whether the shunt is worth it, how much it saved, or how to tune the threshold.
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/haiku-shunt:*)
---

Run the report and present it:

```!
${CLAUDE_PLUGIN_ROOT}/bin/haiku-shunt report $ARGUMENTS
```

Then, briefly:

- Lead with the net figure and whether it is positive.
- Say plainly which numbers are measured and which are modelled. Worker cost is
  measured from the workers' own transcripts. The parent-side saving is a
  model: the counterfactual - whether the file would have been read at all -
  cannot be observed.
- If any denies fell below the printed break-even size, say so and recommend
  raising `SHUNT_MIN_LINES`. Below break-even the plugin costs money rather
  than saving it.
- If `R` is shown as assumed, mention that `haiku-shunt analyze` replaces it
  with a counted value and usually moves the number a lot.

Useful flags: `--parent claude-opus-5`, `--turns N`, `--cache-hit 0.9`,
`--worker-floor N`, `--since DAYS`, `--format json`.
