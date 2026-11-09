# Role contracts

One file per role, `contracts/<role>.json`, for the five agents. A contract says what the role
may use and what it must produce. Three different things happen to its fields, and this page
keeps them apart:

- **Enforced**: code reads the field and blocks a call that goes past it.
- **Derived**: `render.py` writes the field into another file, and `render.py --check` (run by
  `tests/run.sh`) fails when that file differs. What then enforces it is whatever reads that
  other file.
- **Documentation**: nothing reads it to block anything.

| Field | What it says | What happens to it |
|---|---|---|
| `role` | The role's name. It must equal the file name. | Checked by the guard and by `render.py`; a mismatch makes the contract unreadable. |
| `tools` | The agent's tools, by name. | **Derived** into the `tools:` line of `agents/<role>.md` and `templates/agents/adlc-<role>.md.tmpl`. Claude Code applies that line. |
| `shell` | `null` when the role is not narrowed. Otherwise the `gh` command groups it may use, each with its subcommands (`null` = every subcommand of the group), and the `git` subcommands. | **Enforced** by the guard hook on every Bash call the role makes. A `gh` or `git` subcommand outside the lists is blocked. For `git branch`, `git remote` and `--output` the guard adds its own read-only rules. |
| `write_paths` | `null` when not limited. Otherwise the globs, from the repository's top level, that the role may write; `[]` means it writes no file. `**` spans directories, `*` and `?` stay inside one name. | **Enforced** by the guard hook on Edit, Write, MultiEdit and NotebookEdit calls. |
| `labels.may_add` | `null` when not limited. Otherwise the labels the role may put on an issue. It can be a list only where `shell` is set. | **Enforced** by the guard hook on `gh issue edit --add-label` and on `adlc-relabel.sh <issue> <label>`: a label off the list, or a computed one, is blocked. |
| `labels.moves` | The `stage:`/`gate:` moves the role owns: from, to, and who makes the move where. | **Documentation.** `render.py --check` only checks that each `to` is on `may_add` when that is a list. |
| `outputs` | Per duty, the marker lines its comment carries: the form, whether it is required, and which code reads it. A required marker has a `check`: the extended regex of its form, and whether `any` line or the `last` line that carries the marker must match. | The required markers are **derived** into the table inside `templates/scripts/adlc-outputs.sh`. An optional marker is **documentation**. |
| `lanes` | Each Actions step that runs the role: workflow, step name, and the exact tool grant. | **Derived** into that step's `--allowedTools "…"` line in `templates/github/`. Claude Code applies it in the lane, with `--permission-mode dontAsk`. `render.py --check` also refuses a grant that goes past the same contract: a `gh`/`git` command outside `shell`, a bare `Bash` for a narrowed role, an edit grant outside `write_paths`. |
| `inputs` | What the role reads. | **Documentation.** Nothing limits what an agent reads. |

The guard requires `shell`, `write_paths` and `labels.may_add` to be written out, `null`
included: a missing key is an unreadable contract, not "no limit".

## When the guard enforces

The guard hook (`hooks/adlc-guard.sh`, `hooks/adlc_guard.py`) runs in the Actions lanes and in a
local session in a repo that adopted ADLC; elsewhere it does nothing. It takes the role from
the hook input's `agent_type`: the plugin's `adlc:<role>`, a repo's copy `adlc-<role>`, or a bare
`<role>`. The main thread and any other agent have no contract and get the guard's universal
blocks only. It reads the five contracts each time it starts. If a role's contract is missing
or cannot be read, every Bash call and every file write that role makes is blocked.

For a file write, the guard resolves the path the ways the tool may: against the session's
current directory, with `~` expanded or not, and with `..` taken before or after a symbolic
link is followed. Every result must be inside the top level of the git repository the session
is in, at a path one of the globs matches. With no git work tree there, the write is blocked.

## What is not covered

- **A file written through the shell.** `write_paths` covers the four file-writing tools. A
  narrow role holds Bash in a local session, and `echo > file`, `sed -i`, `tee` or a script is
  not checked there. In the lanes the shell is limited to the commands the lane's grant names.
  This is the open part of the write-path rule.
- **Other ways to write.** A hard link, and any tool other than those four (an MCP tool, for
  one), are not seen. The agents' `tools:` lines list no such tool.
- **The Builder's and QA's paths and labels.** Their `shell`, `write_paths` and `may_add` are
  `null`. The diff-scope check judges the paths of their pull request; their label moves are
  held by the prompt.
- **Taking a label off.** Only `--add-label` and the label `adlc-relabel.sh` puts on are checked.
- **The limits of reading command text.** `shell` and `labels.may_add` are checked on the text
  of a Bash command. What the main README says under "It still reads command *text*" applies:
  a script on disk, or code handed to another program, is not read. Text piped into a shell
  (`echo "…" | bash`) is scanned for the blocks that hold for everyone, not against a role's
  lists. And the label check looks for `--add-label` as written: the guard does not expand
  braces, so `{--add-label,x}` is not seen.
- **Outputs before a handoff.** `adlc-outputs.sh` checks a text against the table, and no lane
  calls it yet. Each lane still reads its marker in its own step: `adlc-verdict.sh` for
  `ADLC-ADV` and `ADLC-ARCH`, the intake lane's handoff for `ADLC-TRIAGE`, the design lane's
  handoff for `ADLC-BREAKDOWN` (which also requires the line to name an ADR the run changed).
  Those steps are separate code from the table; `tests/run.sh` runs sample lines through both.
- **Steps that run no role.** The retro's two steps run a skill on the main thread. Their
  grant is not in a contract; `tests/run.sh` pins it.
- **A host repo's copies.** `/adlc-init` copies the workflows, the scripts and the five agent
  files into a repo as frozen files. They follow a contract change only when the repo
  refreshes its tooling. The guard and the contracts are read from the installed plugin.

## Changing a contract

Edit the JSON, then:

```bash
python3 contracts/render.py --write   # rewrite the derived lines
bash tests/run.sh                     # runs --check, the guard cases and the lane checks
```

Widening a lane grant is then a change to `lanes` in a contract, plus the workflow line that
`--write` renders from it. Widening it past the role's `shell` or `write_paths` needs those
fields changed as well, or `--check` refuses it. The guard's list of roles (`ROLES` in
`hooks/adlc_guard.py`) is fixed in code on purpose: a contract file that goes missing blocks
its role instead of lifting its limits.
