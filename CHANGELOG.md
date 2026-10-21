# Changelog

Newest first. Each release says whether a **tooling refresh** is needed. A refresh means
running `/adlc-init` again in your repo: it re-copies the workflows, `.adlc/scripts/*.sh`,
the local hook and the project agents (`.claude/agents/adlc-<role>.md`) from the plugin,
because those are frozen copies that only change on a refresh. Your repo's `.adlc/VERSION`
says which release its copies came from, and `.adlc/scripts/adlc-doctor.sh` tells you when
it differs from the installed plugin.

## Unreleased (on `main` after 0.3.1)

Tooling refresh needed: **no** — the change ships in the plugin's hook script and Mission
Control, which every session and every start use from the installed plugin.

- **One Mission Control shows every adopted repo on the machine, and says so** (issue 52).
  It always could: the hook sends each event with its working directory, the server maps that
  to a repo, and the page's repo menu switches between them. But a repo reached the menu only
  once a pipeline agent had run in it, and a second `adlc-mission-control` in another repo
  answered "already running, stop it first", with `--open` landing on the first repo's line.
  Now the hook script also forwards a session starting; when the session's folder is an
  adopted repo (the guard's own rule: `.adlc/scripts/`, `.adlc/VERSION` or
  `docs/adlc/CHARTER.md` at or above it) the server puts that repo on the menu, and keeps
  nothing from any other session, not even its path. A second start prints the running copy's
  address on the repo it was run from (`?repo=owner/name`) and `--open` opens that; a repo the
  copy has not heard of is named, not linked, since the page would show another repo's line.
  The documented way to run a copy per repo (`ADLC_MC_HOME` and `--port` for each) stays, with
  its limit now written down: a repo's runs land in the per-repo copy only from sessions that
  have that `ADLC_MC_HOME` set; the rest go to the default folder's copy. `--demo` still
  writes nothing; the guard and the server's Host and Origin checks are untouched.

## 0.3.1

Covers everything on `main` after the v0.3.0 tag (`a8ddd97`) up to and including this release
commit, cut on 2026-10-21: pull request 42 (the 0.3.0 marketplace pin) and pull requests 43
to 49, the last of them merged as `c1a9683` on 2026-10-21. The reason to ship it now is the
guard fix below: on a machine that had opened Mission Control, 0.3.0's guard blocks merges and
pushes to `main` in every repository under the home directory.

Tooling refresh needed: **yes** — the RUNBOOK copy gains the Gate 2 check below, the
`adlc-doctor.sh` copy the double-label check, the fast-lane workflow's Action Card a `Base:`
line, and `.adlc/LICENSE` arrives (the MIT notice for the copies). Until then the copies keep
working as they did. The guard fix below needs no refresh of its own: it ships in the
plugin's hook, which every session loads from the installed plugin, not from a copy in your repo.

- **The guard hook no longer treats every repo under your home directory as adopted.** It
  decided scope by looking for any `.adlc/` directory at or above the project, and Mission
  Control keeps its state in `~/.adlc/mission-control`: on a machine that had opened Mission
  Control once, the guard blocked merges and pushes to `main` in every repository under the
  home directory, adopted or not. It now looks for a marker only `/adlc-init` writes —
  `.adlc/scripts/`, `.adlc/VERSION` or `docs/adlc/CHARTER.md` — still at or above the project,
  so a session started in a subdirectory of an adopted repo stays guarded, and the Actions
  lanes stay always in scope. A repo set up by hand with a bare `.adlc/` folder and no charter
  is no longer in scope; the wizard has written the charter since the first release. A repo
  that was guarded only through an `.adlc/` directory above it needs one of the three markers,
  or the deny rules from `templates/settings.deny.json` in its `.claude/settings.json`, to stay
  guarded; this plugin's own checkout, which has no marker, now carries those deny rules.
- **Gate 2 checks the PR is not behind its base before the merge** (issue 40). Two PRs that
  were each green on their own head made `main` red once both were in: the second was
  behind, and a private Free-plan repo cannot require branches to be up to date. The
  RUNBOOK's Gate 2 now asks the compare API how many base commits the PR lacks
  (`gh api "repos/{owner}/{repo}/compare/<base>...<head>" --jq .behind_by`) first; on
  anything but 0 the base is merged into the PR branch and the checks must go green on the
  new head before the merge. (`mergeStateStatus` is not read: it says `BEHIND` only where the
  up-to-date rule is on.) The Action Card format (`release-ops` skill, and the fast lane's
  card) gains a `Base:` line naming the base-branch commit the QA battery ran against, so the
  gap is visible when the base has moved. The RUNBOOK's fast lane now moves the issue
  from `stage:fast` to `gate:deploy` in one `gh issue edit`, as the fast-lane workflow does.
- **The doctor lists open issues and PRs carrying two state-machine labels** (issue 38). In
  its gh-backed section, `adlc-doctor.sh` now flags every open issue or PR with more than one
  `stage:`/`gate:` label, prints each with its labels, and says how to fix it (keep the label
  it reached last; `gh issue edit <n> --remove-label <label>`, `gh pr edit` for a PR). A
  listing that fails is reported as incomplete, not read as clean. Note: under the current
  QA role an approved issue carries `stage:qa` + `gate:deploy` until it closes, so the doctor
  reports it while the PR waits at Gate 2 — the relabel script proposed in issue 38 is what
  removes that pair at the source.
- **Licensed.** Everything outside `templates/` is under the AGPL v3 (`LICENSE-AGPL`);
  everything under `templates/` — the files `/adlc-init` copies into a repo — is under the MIT
  license (`LICENSE-MIT`). `/adlc-init` now copies that notice to `.adlc/LICENSE` beside the
  scripts, so the copies carry it as MIT requires. The README's Licensing section draws the
  line, and `plugin.json` declares `AGPL-3.0-only AND MIT`.
- **Docs.** The README's new "What leaves your machine" section says what Claude Code, `gh`
  and the Actions lanes send out and what stays local, and names the three guard markers and
  where they may sit. `tests/run.sh` prints a note, not a failure, when the marketplace `ref`
  is not `v<version>` of `plugin.json`: the release recipe tags before it moves the ref, so the
  release PR's own CI runs one tag behind by design.

## 0.3.0

Tooling refresh needed: **yes** — `/adlc-init` now writes this repo's copies of the five
agents and a RUNBOOK that invokes them; until then the RUNBOOK copy in your repo still names
the plugin's agents, which keep working. The lane workflows also changed: each prompt now
names the role skill (`adlc:role-<role>`) to load first. A lane copy from 0.2.0 keeps
working, since its prompt already loads the role's skills and the plugin's agents list that
skill first.

Covers everything on `main` after the 0.2.0 tag (`c6dbcd7`) up to and including this release
commit: pull requests 31 to 33, the last of them merged as `516ee27` on 2026-10-20.

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
