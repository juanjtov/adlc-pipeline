"""What Mission Control knows about the ADLC pipeline: the line, its labels, its agents.

Everything here is derived from the plugin's own contract (labels.sh, the charter, the agent
files), so a change there is a change here.
"""
import os
import re

# The line, left to right. Agents work at STATIONS; gates wait for the Principal.
SLOTS = ['intake', 'analyst', 'gate1', 'architect', 'builder', 'reviewer', 'qa', 'gate2', 'done']
STATIONS = ['analyst', 'architect', 'builder', 'reviewer', 'qa']
GATES = ['gate1', 'gate2']
PATH = {
    'full': SLOTS,
    'fast': ['intake', 'analyst', 'gate1', 'builder', 'reviewer', 'gate2', 'done'],
}

# Agent file (agents/<name>.md) -> station.
AGENT_STATION = {
    'product-analyst': 'analyst',
    'architect': 'architect',
    'builder': 'builder',
    'adversarial-reviewer': 'reviewer',
    'qa-release-ops': 'qa',
}
STATION_AGENT = {v: k for k, v in AGENT_STATION.items()}

# The label that puts an issue at a slot. stage:build and stage:fast are refined by PR state.
LABEL_SLOT = {
    'stage:intake': 'analyst',
    'gate:stories': 'gate1',
    'stage:design': 'architect',
    'stage:build': 'builder',
    'stage:fast': 'builder',
    'stage:qa': 'qa',
    'gate:deploy': 'gate2',
}
# When two pipeline labels are present at once (a stale one was not removed), the later stage wins.
LABEL_ORDER = ['stage:intake', 'gate:stories', 'stage:design', 'stage:fast', 'stage:build', 'stage:qa', 'gate:deploy']

TRIAGE_RE = re.compile(r'ADLC-TRIAGE:\s*(FAST|FULL)')
ADV_RE = re.compile(r'ADLC-ADV:\s*(PASS|CHANGES)')
ARCH_RE = re.compile(r'ADLC-ARCH:\s*(PASS|CHANGES)')
FINDING_RE = re.compile(r'ADLC-FINDING:\s*([^|\n]+)\|([^|\n]+)\|([^\n]+)')
ACTION_CARD_RE = re.compile(r'Proposed Action Card', re.I)
ADR_RE = re.compile(r'(?:ADR[ -]?|docs/adr/)(\d{3,4})')

_ISSUE_RE = re.compile(r'\bissue\s+#?(\d+)', re.I)
_PR_RE = re.compile(r'\b(?:PR|pull request)\s+#?(\d+)', re.I)
_HASH_RE = re.compile(r'(?<![\w/])#(\d+)\b')
_BRANCH_RE = re.compile(r'^[^/]*/(\d+)(?:-.*)?$')   # the same rule as templates/scripts/adlc-branch-issue.sh


def station_for(agent_type):
    """'adlc:builder' or 'builder' -> 'builder'. Unknown or empty -> None."""
    if not agent_type:
        return None
    return AGENT_STATION.get(str(agent_type).split(':')[-1])


def refs_in(text):
    """Issue and pull-request numbers named in a task prompt: (issue, pr), either may be None."""
    if not text:
        return None, None
    issue = _ISSUE_RE.search(text)
    pr = _PR_RE.search(text)
    issue_n = int(issue.group(1)) if issue else None
    pr_n = int(pr.group(1)) if pr else None
    if issue_n is None and pr_n is None:
        first = _HASH_RE.search(text)
        if first:
            issue_n = int(first.group(1))
    return issue_n, pr_n


def issue_in_branch(branch):
    """The issue a lane branch names: 'feat/142-password-reset' -> 142, 'feat/142' -> 142, 'main' -> None."""
    m = _BRANCH_RE.match(branch or '')
    return int(m.group(1)) if m else None


def slot_for_labels(labels):
    """The slot an issue's labels put it at, or None when it is not on the line."""
    best = None
    for name in labels:
        if name in LABEL_SLOT and (best is None or LABEL_ORDER.index(name) > LABEL_ORDER.index(best)):
            best = name
    return (LABEL_SLOT[best], best) if best else (None, None)


def _short(path, cwd):
    if not path:
        return ''
    path = str(path)
    if cwd and path.startswith(cwd.rstrip('/') + '/'):
        path = path[len(cwd.rstrip('/')) + 1:]
    return path if len(path) <= 70 else '...' + path[-67:]


def _one_line(text, limit=90):
    text = ' '.join(str(text or '').split())
    return text if len(text) <= limit else text[:limit - 1] + '…'


def step_label(tool, tool_input, cwd=''):
    """A short plain description of one tool call: (kind, label). kind picks the icon."""
    ti = tool_input if isinstance(tool_input, dict) else {}
    tool = tool or 'Tool'
    if tool == 'Bash':
        command = ti.get('command') or ''
        kind = 'gh' if command.lstrip().startswith(('gh ', 'git push', 'git commit')) else 'bash'
        return kind, _one_line(ti.get('description') or command or 'Running a command')
    if tool == 'Read':
        return 'read', 'Reading ' + _short(ti.get('file_path'), cwd)
    if tool in ('Edit', 'MultiEdit', 'NotebookEdit'):
        return 'edit', 'Editing ' + _short(ti.get('file_path') or ti.get('notebook_path'), cwd)
    if tool == 'Write':
        return 'edit', 'Writing ' + _short(ti.get('file_path'), cwd)
    if tool in ('Grep', 'Glob'):
        return 'search', _one_line('Searching for ' + str(ti.get('pattern') or ''))
    if tool in ('WebFetch', 'WebSearch'):
        return 'search', _one_line('Looking up ' + str(ti.get('url') or ti.get('query') or ''))
    if tool == 'Skill':
        return 'read', 'Loading the ' + str(ti.get('skill') or '') + ' skill'
    if tool in ('Task', 'Agent'):
        return 'think', _one_line('Starting ' + str(ti.get('subagent_type') or 'a helper') + ': ' + str(ti.get('description') or ''))
    if tool.startswith('mcp__'):
        return 'gh', _one_line('Calling ' + tool.split('__')[-1].replace('_', ' '))
    return 'think', _one_line(tool)


def read_agent(plugin_root, station):
    """The agent file for a station: frontmatter fields plus the body, which is its system prompt."""
    name = STATION_AGENT[station]
    path = os.path.join(plugin_root, 'agents', name + '.md')
    info = {'station': station, 'agent': name, 'file': 'agents/' + name + '.md', 'prompt': '', 'model': '', 'tools': [], 'skills': []}
    try:
        with open(path, encoding='utf-8') as fh:
            text = fh.read()
    except OSError:
        return info
    m = re.match(r'^---\n(.*?)\n---\n(.*)$', text, re.S)
    front, body = (m.group(1), m.group(2)) if m else ('', text)
    info['prompt'] = body.strip()
    for line in front.splitlines():
        key, _, value = line.partition(':')
        key, value = key.strip(), value.strip()
        if key == 'model':
            info['model'] = value
        elif key == 'tools':
            info['tools'] = _split_tools(value)
    load = re.search(r'^Load:\s*(.+?)(?:\n\n|\Z)', info['prompt'], re.S | re.M)
    if load:
        info['skills'] = _skills_in(' '.join(load.group(1).split()), plugin_root)
    return info


def _split_tools(value):
    """'Read, Bash(gh pr view:*), Bash(git diff:*)' -> ['Read', 'gh pr view', 'git diff']."""
    out, depth, cur = [], 0, ''
    for ch in value + ',':
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            item = cur.strip()
            if item:
                inner = re.match(r'^Bash\((.+?)(?::\*)?\)$', item)
                out.append(inner.group(1) if inner else item)
            cur = ''
        else:
            cur += ch
    return out


def _skills_in(load_line, plugin_root):
    """Skill names from an agent's 'Load:' line. The agent is told to load these; a run may load fewer."""
    return [{'name': name, 'tok': skill_tokens(plugin_root, '', name)} for name in re.findall(r'`([^`]+)`', load_line)]


def skill_tokens(plugin_root, cwd, name):
    """A size estimate for a skill: the plugin's own skills first, then the project's. None when the file is not found."""
    short = str(name).split(':')[-1]
    for base in (os.path.join(plugin_root or '', 'skills'), os.path.join(cwd or '', '.claude', 'skills')):
        try:
            return est_tokens(os.path.getsize(os.path.join(base, short, 'SKILL.md')))
        except OSError:
            continue
    return None


def est_tokens(chars):
    """A rough token count for text we can read: about four characters a token."""
    return int(round((chars or 0) / 4.0))
