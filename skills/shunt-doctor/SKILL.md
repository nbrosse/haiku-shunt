---
name: shunt-doctor
description: Check that haiku-shunt is installed correctly and that the assumptions behind its cost model still hold on this machine. Use after installing, after a Claude Code upgrade, or when the shunt seems not to fire.
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/haiku-shunt:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/evals/run.sh:*)
---

```!
${CLAUDE_PLUGIN_ROOT}/bin/haiku-shunt doctor
```

Report anything marked FAIL or warn. Then note the two things `doctor` cannot
check on its own, because they need a live delegation:

1. **Does `agent_type` still reach the hook, and in what form?** Plugin agents
   are namespaced (`haiku-shunt:bulk-reader`), and the guard depends on it. If
   this ever changes, the worker's own reads get denied and every large file
   costs extra turns.
2. **Is the worker really on Haiku?** `claude plugin validate` does not check
   the `model:` field at all - it will happily accept a nonexistent model.

Both are confirmed by delegating once and then running:

```
${CLAUDE_PLUGIN_ROOT}/bin/haiku-shunt analyze
```

If the hooks are misbehaving, the full offline suite is the fastest way to
localise it:

```
bash ${CLAUDE_PLUGIN_ROOT}/evals/run.sh -v
```
