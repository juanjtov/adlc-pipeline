# Changelog

Newest first. Each release says whether a **tooling refresh** is needed. A refresh means
running `/adlc-init` again in your repo: it re-copies the workflows, `.adlc/scripts/*.sh`,
the local hook and the project agents (`.claude/agents/adlc-<role>.md`) from the plugin,
because those are frozen copies that only change on a refresh. Your repo's `.adlc/VERSION`
says which release its copies came from, and `.adlc/scripts/adlc-doctor.sh` tells you when
it differs from the installed plugin.

## Unreleased (on `main` after 0.3.0)

Tooling refresh needed: **no** — a re-run only adds `.adlc/LICENSE`, the MIT notice for the
copies already in your repo; nothing they do changes.

- **Licensed.** Everything outside `templates/` is under the AGPL v3 (`LICENSE-AGPL`);
  everything under `templates/` — the files `/adlc-init` copies into a repo — is under the MIT
  license (`LICENSE-MIT`). `/adlc-init` now copies that notice to `.adlc/LICENSE` beside the
  scripts, so the copies carry it as MIT requires. The README's Licensing section draws the
  line, and `plugin.json` declares `AGPL-3.0-only AND MIT`.

## 0.3.0

Tooling refresh needed: **yes** — `/adlc-init` now writes this repo's copies of the five
agents and a RUNBOOK that invokes them; until then the RUNBOOK copy in your repo still names
the plugin's agents, which keep working. The lane workflows also changed: each prompt now
names the role skill (`adlc:role-<role>`) to load first. A lane copy from 0.2.0 keeps
working, since its prompt already loads the role's skills and the plugin's agents list that
skill first.

Covers everything on `main` after the 0.2.0 tag (`04b7ad2`) up to and including this release
commit: pull requests 31 to 33, the last of them merged as `6292a21` on 2026-10-20.

- **The model per agent is yours.** Each role prompt is now a plugin skill
  (`adlc:role-<role>`) and the plugin's agents are thin wrappers that preload it with the
  role's other skills. `/adlc-init` writes the same wrappers into your repo as
  `.claude/agents/adlc-<role>.md`, asking which model each one runs on (defaults: `opus` for
  the Analyst, the Architect and QA/Ops; `fable` for the Builder and the reviewer); the
  RUNBOOK invokes those copies, and `/adlc-model` prints the five models or changes one. The
  Actions lanes still run the plugin's `adlc:<role>` agents with the plugin's defaults. A
  copy reports to hooks as `adlc-<role>`, so the guard hook, Mission Control and the run
  ledger treat it as the role, like `adlc:<role>`. The doctor checks the five copies exist
  and each has a model.
- **Docs.** The README's At a glance chart is now a hero image that shows the pipeline and
  Mission Control, in place of the Mermaid flowchart; `docs/readme-hero.py` regenerates it.

## 0.2.0

Tooling refresh needed: **yes** for a repo set up before this release (its copies predate
the lane wiring, the trusted guards and the fixes below, and it has no `.adlc/VERSION`).
**No** for a repo set up with this release.

This is the first tagged release. `plugin.json` has said `0.2.0` since 2026-10-03, so a
machine that installed before this tag has a cache entry under the same version string, and
`claude plugin update` may report it as already current. Such a machine should uninstall and
reinstall `adlc@adlc-pipeline` (untested here). The next release avoids this by bumping the
version. It covers everything on `main` up to 2026-10-16.

- **Lanes run as their agents.** Each Actions lane installs the plugin, runs as its named
  agent (`--agent adlc:<role>`) and gets only that lane's tools. `tests/run.sh` pins every
  lane's agent and tool grant. The plugin's guard hook blocks merge, push-to-main and
  force-push, and now also a `gh` alias definition or `git -c alias.…`, which could hide one.
- **Diff guards run from the default branch.** The diff-scope workflow (the scope check and
  the fast-lane cap check) runs on `pull_request_target`, so its workflow and scripts are the
  default branch's and a pull request cannot edit the check that judges it. The scope file is
  read as a git blob and a link at the scope folder is refused.
- **Fast lane.** Trivial changes can skip design and Gate 1. The cap fails closed, a
  submodule change (and `.gitmodules`) is never fast-eligible, and a human approves the
  lane.
- **Fix loop.** The cap counts only the pull request's own fix rounds.
- **Intake.** `/adlc-intake` is one front door for an idea, a PRD, an issue, a bug or a
  ticket from another tracker. It files a sharpened `stage:intake` issue only on a yes.
- **Mission Control.** `/adlc-mission-control` opens a local, live view of the pipeline
  (stations, requests, tokens, cost). It reads GitHub through your `gh` login.
- **Doctor.** Checks that every agent step installs the plugin and grants tools, that the
  scripts the lanes call are installed, and, when `gh` can ask, that the default branch has
  a merge gate (an approving review, or at least the tripwire). It runs `gh` inside the
  repo named by its argument. New: it compares `.adlc/VERSION` with the plugin's version.
- **Metrics.** `first_pass_approved` counts pull requests with no CHANGES verdict comment,
  reading a comment's last marker as `adlc-verdict.sh` does.
- **Guard fixes ported from a host repo.** Nine scripts hardened in a real repo are back in
  the templates: a failed lookup no longer reads as "nothing to check" (tripwire, fix cap,
  verdict, diff-scope), and the tripwire workflow has the `pull-requests: read` it needs on
  a private repo.
- **Cycle retro.** A `cycle-retro` skill reads a run ledger (`adlc-run-log.sh`: tokens, cost and
  latency per agent run, from Mission Control, OpenTelemetry or Actions data) and per-issue
  cycle times from the label timeline (`adlc-cycle.sh`), then proposes changes in one pull
  request. It never merges.
- **Docs.** README has an At a glance section, a version badge and a commands table;
  `docs/` has a plain-language explainer and a one-page diagram.
- **Release process.** Releases are git tags. `main` is development. The marketplace entry
  is pinned to the release tag, so installs and the Actions runner get the tagged release,
  not whatever is on `main`.

## How a release is cut

1. On `main`, bump `version` in `.claude-plugin/plugin.json`. Only the release commit
   changes it: Claude Code keys its cache on that string, so users see an update only
   when it changes.
2. Add the entry above, with its "Tooling refresh needed" line. A refresh is needed when
   the release changes anything under `templates/` that `/adlc-init` copies into a repo.
3. Commit, then tag the commit `vX.Y.Z` and push the tag.
4. In `.claude-plugin/marketplace.json`, move the `adlc` entry's `ref` to the new tag and
   push. Run `claude plugin validate .` first.
5. Users get it with `claude plugin update adlc@adlc-pipeline`. Lanes get it on their next
   run.

Rollback: move the marketplace `ref` back to the previous tag and push. Claude Code has no
rollback command, and how an already-updated machine reacts to an older version string is
not verified here, so test it before relying on it.

Plugin development does not need a release: run `claude --plugin-dir <checkout>`.
