#!/usr/bin/env python3
"""Check, or rewrite, the text that is derived from the role contracts (contracts/<role>.json).

    python3 contracts/render.py --check    exit 1 and name each drift; exit 0 when there is none
    python3 contracts/render.py --write    rewrite the derived text in place, then check again

Derived (rewritten by --write):
  * the `tools:` line of agents/<role>.md and templates/agents/adlc-<role>.md.tmpl
  * the `--allowedTools "…"` line of every step that runs `--agent adlc:<role>` in
    templates/github/*.yml
  * the table of required markers inside templates/scripts/adlc-outputs.sh

Checked only (a drift here needs a person):
  * each contract's shape — the enforced fields exactly as hooks/adlc_guard.py reads them
  * the contract files are the guard's five roles, no more and no fewer
  * every agent step names a role and has one lane entry in that role's contract, and every
    lane entry has its step
  * no lane grant goes past the role's own contract: a gh or git command outside `shell`, a
    bare Bash for a narrowed role, an Edit or Write outside `write_paths`

A step with no `--agent` (the retro's two skill runs) belongs to no role and is not looked at
here; tests/run.sh pins those two grants by hand. Standard library only; Python 3.9.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True  # importing the guard must not leave a __pycache__ in hooks/
sys.path.insert(0, os.path.join(ROOT, "hooks"))
import adlc_guard  # noqa: E402 — the guard's own reading of the enforced fields

KEYS = ("role", "tools", "shell", "write_paths", "labels", "outputs", "lanes", "inputs")
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
OUTPUTS = "templates/scripts/adlc-outputs.sh"
TABLE_START = "# >>> rendered by contracts/render.py"
TABLE_END = "# <<< rendered"
AGENT_ACTION = re.compile(r"uses:\s*anthropics/claude-code-action\b")
GRANT_LINE = re.compile(r'^(\s*--allowedTools\s+")([^"]*)(".*)$')


def text_ok(value):
    return isinstance(value, str) and value.strip() == value and value and "\t" not in value and "\n" not in value


def shape(role, doc):
    """Problems in the fields the guard does not read (it has checked the others already)."""
    out = []
    if tuple(doc) != KEYS:
        out.append("the keys must be exactly %s, in that order (found %s)" % (", ".join(KEYS), ", ".join(doc)))
        return out
    tools = doc["tools"]
    if not (isinstance(tools, list) and tools and all(isinstance(t, str) and re.fullmatch(r"[A-Za-z]+", t) for t in tools)):
        out.append("`tools` must be a list of plain tool names (a `tools:` line takes no command specifier)")
        return out
    if "Skill" not in tools:
        out.append("`tools` lacks Skill (the agent could not load its skills)")
    if doc["write_paths"] == [] and any(t in tools for t in EDIT_TOOLS):
        out.append("`write_paths` is [] (the role writes no file) but `tools` holds an edit tool")
    if doc["shell"] is not None and "Bash" not in tools:
        out.append("`shell` is set but `tools` has no Bash")
    moves = doc["labels"].get("moves")
    if set(doc["labels"]) != {"may_add", "moves"} or not isinstance(moves, list) or not all(
            isinstance(m, dict) and tuple(m) == ("from", "to", "by") and all(text_ok(v) for v in m.values())
            for m in moves):
        out.append("`labels` must hold `may_add` and `moves`, each move a {from, to, by} of strings")
    elif doc["labels"]["may_add"] is not None:
        for m in moves:
            if m["to"] not in doc["labels"]["may_add"]:
                out.append("`labels.moves` ends at %s, which `labels.may_add` does not allow" % m["to"])
    outputs = doc["outputs"]
    if not isinstance(outputs, dict):
        out.append("`outputs` must be an object: duty -> {where, markers}")
        outputs = {}
    for duty, spec in outputs.items():
        where = "`outputs.%s`" % duty
        if not re.fullmatch(r"[a-z][a-z-]*", duty) or not isinstance(spec, dict) or tuple(spec) != ("where", "markers") \
                or not text_ok(spec["where"]) or not isinstance(spec["markers"], list) or not spec["markers"]:
            out.append("%s must be {where, markers} under a lower-case duty name" % where)
            continue
        for m in spec["markers"]:
            required = m.get("required") if isinstance(m, dict) else None
            want = ("marker", "form", "required", "check", "read_by") if required else ("marker", "form", "required", "read_by")
            if not isinstance(m, dict) or tuple(m) != want or not isinstance(required, bool) \
                    or not all(text_ok(m[k]) for k in ("marker", "form", "read_by")):
                out.append("%s: a marker is {marker, form, required, read_by}, plus `check` when it is required" % where)
                continue
            if not re.fullmatch(r"ADLC-[A-Z]+", m["marker"]) or not m["form"].startswith(m["marker"] + ": "):
                out.append("%s: `%s` must be ADLC-<NAME>, and its form must start with it" % (where, m["marker"]))
            check = m.get("check")
            if required and not (isinstance(check, dict) and tuple(check) == ("line", "ere")
                                 and check["line"] in ("any", "last") and text_ok(check["ere"])
                                 and (m["marker"] + ":") in check["ere"]):
                out.append("%s: `check` of %s must be {line: any|last, ere: a regex that names the marker}"
                           % (where, m["marker"]))
    lanes = doc["lanes"]
    if not isinstance(lanes, list) or not all(
            isinstance(e, dict) and tuple(e) == ("workflow", "step", "allowedTools") and text_ok(e["workflow"])
            and text_ok(e["step"]) and isinstance(e["allowedTools"], list) and e["allowedTools"]
            and all(text_ok(t) and '"' not in t and "," not in t for t in e["allowedTools"]) for e in lanes):
        out.append("`lanes` must be a list of {workflow, step, allowedTools}, the grant a list of single tools")
        return out
    for e in lanes:
        for why in beyond(doc, e["allowedTools"]):
            out.append("lane %s, step \"%s\": %s" % (e["workflow"], e["step"], why))
    if not isinstance(doc["inputs"], list) or not all(text_ok(x) for x in doc["inputs"]):
        out.append("`inputs` must be a list of strings")
    return out


def beyond(doc, grant):
    """Why a lane grant goes past the role's own contract (one line per offending tool)."""
    tools, shell, writes = doc["tools"], doc["shell"], doc["write_paths"]
    out = []
    for item in grant:
        m = re.fullmatch(r"([A-Za-z]+)(?:\((.*)\))?", item)
        if not m:
            out.append("`%s` is not a tool grant" % item)
            continue
        name, spec = m.group(1), m.group(2)
        if name not in tools:
            out.append("`%s`: the role's `tools` has no %s" % (item, name))
        elif name == "Bash" and shell is not None:
            if spec is None:
                out.append("a bare `Bash` for a role whose `shell` is narrowed")
                continue
            words = spec[:-2].split() if spec.endswith(":*") else spec.split()

            def gh_allows(group, sub):
                subs = shell["gh"].get(group, ())
                return subs is None or sub in subs

            if words[:1] == ["gh"] and len(words) in (2, 3):
                if not gh_allows(words[1], words[2] if len(words) == 3 else None):
                    out.append("`%s` is outside the role's `shell.gh`" % item)
            elif words[:1] == ["git"] and len(words) == 2:
                if words[1] not in shell["git"]:
                    out.append("`%s` is outside the role's `shell.git`" % item)
            elif len(words) == 1 and re.fullmatch(r"\.adlc/scripts/adlc-[a-z-]+\.sh", words[0]):
                script = words[0].rsplit("/", 1)[1]
                if not os.path.isfile(os.path.join(ROOT, "templates", "scripts", script)):
                    out.append("`%s`: templates/scripts/ has no %s" % (item, script))
                elif script == "adlc-relabel.sh" and not gh_allows("issue", "edit"):
                    out.append("`%s` is `gh issue edit`, which is outside the role's `shell.gh`" % item)
            else:
                out.append("`%s`: cannot tell whether this is inside the role's `shell`" % item)
        elif name in EDIT_TOOLS and writes is not None:
            if spec is None or spec not in writes:
                out.append("`%s` is outside the role's `write_paths`" % item)
        elif spec is not None and not (name == "Bash" or name in EDIT_TOOLS):
            out.append("`%s`: a specifier on a tool this check does not know" % item)
    return out


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8", newline="") as f:
        return f.read()


def load(problems):
    """role -> its contract, for every contract that can be read; the rest go to `problems`."""
    folder = os.path.join(ROOT, "contracts")
    found = sorted(f[:-len(".json")] for f in os.listdir(folder) if f.endswith(".json"))
    if found != sorted(adlc_guard.ROLES):
        problems.append("contracts/: the files must be the guard's roles (%s), found %s"
                        % (", ".join(sorted(adlc_guard.ROLES)), ", ".join(found) or "none"))
    contracts = {}
    for role in adlc_guard.ROLES:
        rel = "contracts/%s.json" % role
        try:
            adlc_guard.read_contract(role, folder)
            doc = json.loads(read(rel))
        except (adlc_guard.ContractError, OSError, ValueError) as e:
            problems.append("%s: the guard cannot read it: %s" % (rel, e))
            continue
        bad = shape(role, doc)
        problems.extend("%s: %s" % (rel, why) for why in bad)
        if not bad:
            contracts[role] = doc
    return contracts


def agent_steps(lines):
    """The steps that run claude-code-action: {name, agent, grant: [line indexes]} in file order.
    A step is a list item at the indent of the first one under a `steps:` key; a deeper `- ` (a
    bullet in a prompt) is not one."""
    steps, item, step, expect = [], None, None, False
    for i, line in enumerate(lines):
        body = line.strip()
        if not body or body.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if item is not None and indent < item:
            item = step = None  # the job's step list ended
        if re.fullmatch(r"steps:", body) and (item is None or indent < item):
            item, step, expect = None, None, True
            continue
        if expect:
            expect = False
            if body.startswith("- "):
                item = indent
        if item is None:
            continue
        if indent == item and body.startswith("- "):
            step = {"name": None, "agent": None, "grant": [], "action": False}
            body, indent = body[2:].lstrip(), item + 2
            key = True
        else:
            key = indent == item + 2
        if step is None:
            continue
        if key and body.startswith("name:"):
            step["name"] = body[len("name:"):].strip()
        elif key and AGENT_ACTION.match(body):
            step["action"] = True
            steps.append(step)
        elif step["action"]:
            m = re.fullmatch(r"--agent\s+(\S+)", body)
            if m:
                step["agent"] = step["agent"] or m.group(1)
            elif GRANT_LINE.match(line):
                step["grant"].append(i)
    return steps


def derive(problems):
    """rel path -> the text it should hold, for every derived file that differs; what cannot be
    derived goes to `problems`. Each drift is described in `problems` too."""
    contracts = load(problems)
    edits = {}

    def want(rel, text, new, what):
        if new != text:
            edits[rel] = new
            problems.append("%s: %s" % (rel, what))

    # 1) tools: lines
    for role, doc in contracts.items():
        line = "tools: " + ", ".join(doc["tools"])
        for rel in ("agents/%s.md" % role, "templates/agents/adlc-%s.md.tmpl" % role):
            try:
                text = read(rel)
            except OSError as e:
                problems.append("%s: %s" % (rel, e))
                continue
            front = re.match(r"---\r?\n(.*?\r?\n)---\r?\n", text, re.S)
            found = re.findall(r"^tools:[^\r\n]*", front.group(1), re.M) if front else []
            if len(found) != 1:
                problems.append("%s: the frontmatter must have exactly one `tools:` line" % rel)
                continue
            at = text.index(found[0])
            want(rel, text, text[:at] + line + text[at + len(found[0]):],
                 "its tools line is `%s`, the contract says `%s`" % (found[0], line))

    # 2) --allowedTools of every agent step
    used = set()
    folder = os.path.join(ROOT, "templates", "github")
    for name in sorted(f for f in os.listdir(folder) if f.endswith((".yml", ".yaml"))):
        rel = "templates/github/" + name
        text = read(rel)
        lines = text.split("\n")
        for step in agent_steps(lines):
            if step["agent"] is None:
                continue  # a skill run on the main thread: no role, not derived here
            where = "%s, step \"%s\"" % (rel, step["name"])
            role = step["agent"][len("adlc:"):] if step["agent"].startswith("adlc:") else None
            if role not in adlc_guard.ROLES:
                problems.append("%s: runs `--agent %s`, which is not one of the plugin's roles" % (where, step["agent"]))
                continue
            if role not in contracts:
                continue  # its contract is already reported as unreadable
            entries = [k for k, e in enumerate(contracts[role]["lanes"])
                       if e["workflow"] == name and e["step"] == step["name"]]
            if len(entries) != 1:
                problems.append("%s: contracts/%s.json must have exactly one lane entry for it (found %d)"
                                % (where, role, len(entries)))
                continue
            used.add((role, entries[0]))
            if len(step["grant"]) != 1:
                problems.append("%s: must have exactly one `--allowedTools \"…\"` line (found %d)"
                                % (where, len(step["grant"])))
                continue
            grant = ",".join(contracts[role]["lanes"][entries[0]]["allowedTools"])
            m = GRANT_LINE.match(lines[step["grant"][0]])
            if m.group(2) != grant:
                lines[step["grant"][0]] = m.group(1) + grant + m.group(3)
                problems.append("%s: grants `%s`, contracts/%s.json says `%s`" % (where, m.group(2), role, grant))
        if "\n".join(lines) != text:
            edits[rel] = "\n".join(lines)
    for role, doc in contracts.items():
        for k, e in enumerate(doc["lanes"]):
            if (role, k) not in used:
                problems.append("contracts/%s.json: lane entry %s, step \"%s\": no step of that name runs "
                                "`--agent adlc:%s` there" % (role, e["workflow"], e["step"], role))

    # 3) the marker table of adlc-outputs.sh
    rows = ["\t".join((role, duty, m["marker"], m["check"]["line"], m["form"], m["check"]["ere"]))
            for role, doc in contracts.items() for duty, spec in doc["outputs"].items()
            for m in spec["markers"] if m["required"]]
    try:
        text = read(OUTPUTS)
        head, rest = text.split(TABLE_START, 1)
        _, tail = rest.split(TABLE_END, 1)
        opener = rest.split("\n", 1)[0]
    except (OSError, ValueError):
        problems.append("%s: missing, or it lacks the `%s` … `%s` block" % (OUTPUTS, TABLE_START, TABLE_END))
    else:
        block = "\n".join([
            TABLE_START + opener,
            "# role, duty, marker, which line (any|last), form, the extended regex of the form; tab-separated",
            "table() { cat <<'ADLC_OUTPUTS'"] + rows + ["ADLC_OUTPUTS", "}", ""])
        if len(contracts) == len(adlc_guard.ROLES):  # never render a table from a partial read
            want(OUTPUTS, text, head + block + TABLE_END + tail,
                 "its marker table is not what the contracts' required markers render to")
    return edits


def main(argv):
    if argv not in (["--check"], ["--write"]):
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        return 2
    problems = []
    edits = derive(problems)
    if argv == ["--write"]:
        for rel, text in sorted(edits.items()):
            with open(os.path.join(ROOT, rel), "w", encoding="utf-8", newline="") as f:
                f.write(text)
            print("rewrote %s" % rel)
        problems = []
        derive(problems)  # what is left is not derivable: a person has to fix it
    for line in problems:
        sys.stderr.write("drift: %s\n" % line)
    if not problems:
        print("contracts: no drift (%d roles)" % len(adlc_guard.ROLES))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
