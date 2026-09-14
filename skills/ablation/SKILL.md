---
name: ablation
description: Periodically reset and prune this repo's agent context (CLAUDE.md, skills, agent defs, hooks) so it doesn't rot into append-only. Run the reset protocol, apply the keep/cut test, and log what earned its way back. Reach for this on a new model generation, every ~6 months, or when CLAUDE.md has crept past ~50 lines.
---

# Ablation — prune the context

Every line of persistent context is a tax paid on every request; it must earn its place
against what the model does unprompted. Reactive maintenance quietly becomes append-only —
each bad session adds a line, none ever removes one. This is the only loop that runs the
other way, so it has to be scheduled, not triggered.

## When to run

- A new model generation ships.
- Every ~6 months on active repos.
- `CLAUDE.md` has crept past ~50 lines, or rules are visibly competing.
- After a major restructure (then re-check gotchas only — don't re-add everything).

## Reset protocol

1. **Snapshot & audit.** `git checkout -b context-ablation`. Inventory every surface that
   injects persistent context: user + project `CLAUDE.md`, `.claude/skills/**`, every agent
   def, hooks, and any `@` imports. Run `/doctor` first — it proposes cuts it can derive from
   the code and reports before changing anything.
2. **Delete to empty** (not trimmed). If that feels reckless, keep exactly one thing: the
   commands the model can't guess (build/test/lint/deploy).
3. **Work normally for a week.** Do real tasks; re-add nothing preemptively. Log failures:
   `DATE | TASK | WHAT IT DID WRONG | REPEATED? (y/n)`.
4. **Re-add one line at a time**, only if **all three** hold: the model got it wrong; more
   than once across separate sessions; and a smart model reading the repo couldn't have
   figured it out. Then place it at the cheapest effective layer (below).
5. **Record** each re-added line in `CONTEXT-LOG.md` with its date and the failure that
   justified it. Next reset, this file tells you what was re-earned vs cargo cult.

## Placement order (cheapest fix first)

1. Can a **tool / script / config** make the failure impossible? Do that — zero context cost.
2. Must it happen every time, deterministically? → **hook** (`.claude/settings.json`).
3. Repeatable procedure needed sometimes? → **skill**.
4. Gotcha needed on most tasks? → **`CLAUDE.md`**.
5. Missing context from an external system? → **MCP server**.

## Keep/cut test (apply to every existing line; cut on any "no")

1. Would removing it cause a mistake? (no → cut)
2. Could the model learn it by reading the repo? (yes → cut)
3. True for *every* task? — CLAUDE.md lines (no → move to a skill)
4. Conflicts with another layer? (yes → resolve or cut both)
5. Bare prohibition with no rationale? (rewrite with rationale, or cut)
6. Enumerates steps instead of stating an outcome? (yes → cut/rewrite)
7. Belongs in CI / a linter / a hook? (yes → move)
8. Written for a model two generations old? (yes → cut)

`IMPORTANT` raises adherence for *one* line; it stops working the moment it's on five.
Apply this test to the **agent definitions and skills too**, including this plugin's — an
agent that mainly restates "be careful, think first" is a deletion candidate; one that
exists to restrict the tool set earns its keep structurally.
