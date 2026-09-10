---
name: shunt-doctor
description: Check that haiku-shunt is installed correctly and print the break-even file size below which delegating loses money. Use after installing, after a Claude Code upgrade, or when the shunt seems not to fire.
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/haiku-shunt:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/evals/run.sh:*)
---

```!
${CLAUDE_PLUGIN_ROOT}/bin/haiku-shunt doctor
```

Report anything marked FAIL or warn. The break-even figures are an order of
magnitude from assumed values, not a measurement; say so. Then note the two
things `doctor` cannot check on its own, because they need a live delegation:

1. **Does `agent_type` still reach the hook, and in what form?** Plugin agents
   are namespaced (`haiku-shunt:bulk-reader`), and the guard depends on it. If
   this ever changes, the worker's own reads get denied and every large file
   costs extra turns. `doctor` shows it once the recursion guard has fired.
2. **Is the worker really on Haiku?** `claude plugin validate` does not check
   the `model:` field at all - it will happily accept a nonexistent model.
   After a delegation, check `message.model` in the worker's transcript under
   `~/.claude/projects/<project>/<session>/subagents/agent-*.jsonl`. A Haiku
   entry in `modelUsage` is not proof: Claude Code makes a small Haiku call of
   its own in every session.

If the hooks are misbehaving, the full offline suite is the fastest way to
localise it:

```
bash ${CLAUDE_PLUGIN_ROOT}/evals/run.sh -v
```
