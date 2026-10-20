---
description: Show or set the model each ADLC agent runs on in this repo — the model line of .claude/agents/adlc-<role>.md.
argument-hint: "[<role> <model>]   roles: product-analyst | architect | builder | adversarial-reviewer | qa-release-ops"
---

Show or change which model an ADLC agent runs on in this repository. Arguments: $ARGUMENTS

The agents the RUNBOOK invokes are this repo's copies of the plugin's five, written by
`/adlc-init` to `.claude/agents/adlc-<role>.md`; each file's `model:` line is the setting.
Roles: `product-analyst`, `architect`, `builder`, `adversarial-reviewer`, `qa-release-ops`.

**No arguments:** read the `model:` line of each of the five files and print one table,
role → model. A missing file shows as "not installed — run /adlc-init". Change nothing.

**`<role> <model>`:** the role must be one of the five and its file must exist; otherwise say
so and stop. Change only that file's `model:` line to the value given — an alias (`opus`,
`sonnet`, `haiku`, `fable`), a full model name, or `inherit` (the invoking session's model) —
and touch no other line. Then show `git diff -- .claude/agents/adlc-<role>.md` and stop.
Commit nothing.

End by stating two facts: a model named in the call itself still wins over the file for that
call (the Agent tool's `model` parameter, or `--model` for a session), and the plugin's own
`adlc:<role>` agents — what the Actions lanes run — keep the plugin's defaults; this command
changes this repo's copies only.
