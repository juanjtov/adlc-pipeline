"""What Mission Control knows about the ADLC pipeline: the line, its labels, its agents.

Everything here is derived from the plugin's own contract (labels.sh, the charter, the agent
files), so a change there is a change here.
"""
import importlib.util
import os
import re

# The line, left to right. Agents work at STATIONS; gates wait for the Principal.
SLOTS = ['intake', 'analyst', 'gate1', 'architect', 'builder', 'reviewer', 'qa', 'gate2', 'done']
STATIONS = ['analyst', 'architect', 'builder', 'reviewer', 'qa']
GATES = ['gate1', 'gate2']

# Claude Code reports a plugin's agent as '<plugin name>:<agent file name>'. Only this plugin's agents are pipeline agents:
# another plugin's 'builder', or a project's own 'architect', is not.
PLUGIN = 'adlc'
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
# The order of the stages, used only when two pipeline labels are present and nothing says which was added last.
LABEL_ORDER = ['stage:intake', 'gate:stories', 'stage:design', 'stage:fast', 'stage:build', 'stage:qa', 'gate:deploy']

TRIAGE_RE = re.compile(r'ADLC-TRIAGE:\s*(FAST|FULL)')
ADV_RE = re.compile(r'ADLC-ADV:\s*(PASS|CHANGES)')
ARCH_RE = re.compile(r'ADLC-ARCH:\s*(PASS|CHANGES)')
ACTION_CARD_RE = re.compile(r'Proposed Action Card', re.I)
ADR_RE = re.compile(r'(?:ADR[ -]?|docs/adr/)(\d{3,4})')

_ISSUE_RE = re.compile(r'\bissue\s+#?(\d+)', re.I)
_PR_RE = re.compile(r'\b(?:PR|pull request)\s+#?(\d+)', re.I)
_HASH_RE = re.compile(r'(?<![\w/])#(\d+)\b')
_BRANCH_RE = re.compile(r'^[^/]*/(\d+)(?:-.*)?$')   # the same rule as templates/scripts/adlc-branch-issue.sh


def station_for(agent_type):
    """'adlc:builder' -> 'builder'. Anything that is not one of this plugin's five agents -> None."""
    plugin, _, name = (agent_type if isinstance(agent_type, str) else '').partition(':')
    return AGENT_STATION.get(name) if plugin == PLUGIN else None


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


def slot_for_labels(labels, events=()):
    """The slot an issue's labels put it at, and the label that says so. (None, None) when it is not on the line.

    Two pipeline labels can be present at once when a move left the old one behind. The one added last wins, as in
    the lanes: adlc-intake.yml reads a stage:intake beside a leftover gate:stories as "the Analyst has not finished".
    `events` is the issue's label history, oldest first. Without it the later stage wins.
    """
    present = [name for name in labels if name in LABEL_SLOT]
    if not present:
        return None, None
    added = {}
    for e in events:
        if e.get('added') and e.get('ts') and e.get('label') in present:
            added[e['label']] = e['ts']
    pool = added or dict.fromkeys(present, 0)
    best = max(pool, key=lambda name: (pool[name], LABEL_ORDER.index(name)))
    return LABEL_SLOT[best], best


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
    """The agent file for a station — frontmatter fields plus the body, which is its system prompt — and what the
    plugin lets that agent run: the guard hook's command limits (a local run) and each Actions lane's grant.
    Nothing here is typed in: it is read from agents/, hooks/adlc_guard.py and templates/github/."""
    name = STATION_AGENT[station]
    path = os.path.join(plugin_root, 'agents', name + '.md')
    info = {'station': station, 'agent': name, 'file': 'agents/' + name + '.md', 'prompt': '', 'model': '', 'tools': [],
            'blocked': [], 'lanes': [], 'guard': 'missing'}
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
    # An agent file's `tools:` names whole tools. What a narrow role may run THROUGH Bash is held by the plugin's
    # guard hook, so that is where the truth is: show its commands in place of a bare "Bash". When the guard cannot
    # be read, the line stands as written and 'guard' says so — the page then shows that the limits are unknown.
    limits = _guard_limits(plugin_root, name)
    if limits is not None:
        info['guard'] = 'ok'
        if limits and 'Bash' in info['tools']:
            at = info['tools'].index('Bash')
            info['tools'][at:at + 1] = limits
        info['blocked'] = _guard_blocks(info['tools'], bool(limits))
    info['lanes'] = _lane_grants(plugin_root, name)
    return info


# What the guard hook blocks for every agent, in every permission mode.
GUARD_BLOCKS = ['gh pr merge', 'Push to main', 'Force-push', 'GitHub API writes']


def _guard_blocks(tools, narrow):
    """What this agent cannot do: the guard's universal blocks; its command list, for a narrow role; and the
    edit tools its file does not grant."""
    out = list(GUARD_BLOCKS)
    if narrow:
        out.append('Other gh and git commands')
    out += [t for t in ('Edit', 'Write') if t not in tools]
    return out


def _guard_limits(plugin_root, agent):
    """The gh and git commands the guard hook (hooks/adlc_guard.py) allows a narrow role, e.g.
    ['gh pr diff', 'gh pr view', 'git (read-only)']. [] when the role holds the whole shell. None when the guard
    cannot be read — the caller must not pass that off as "no limits"."""
    try:
        spec = importlib.util.spec_from_file_location('adlc_guard', os.path.join(plugin_root, 'hooks', 'adlc_guard.py'))
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        rules = guard.ROLE_RULES.get(agent)
        lookups = set(guard.READ_GH)        # gh auth status and the like: every role keeps them, not worth a chip
    except Exception:
        return None
    if not rules:
        return []
    out = []
    for group in sorted(set(rules['gh']) - lookups):
        subs = rules['gh'][group]
        out += ['gh ' + group] if subs is None else ['gh %s %s' % (group, sub) for sub in sorted(subs)]
    return out + ['git (read-only)']


LANE_AGENT_RE = re.compile(r'^\s*--agent\s+adlc:([a-z-]+)\s*$')
LANE_TOOLS_RE = re.compile(r'--allowedTools\s+"([^"]*)"')


def _lane_grants(plugin_root, agent):
    """What each GitHub Actions lane grants this agent: in templates/github/adlc-*.yml, the `--allowedTools` of the
    step that runs `--agent adlc:<name>`. A lane may grant less than the guard allows the role (the review lane
    gives the Architect no `gh pr review`). [] when the templates are not there."""
    folder = os.path.join(plugin_root, 'templates', 'github')
    try:
        files = sorted(f for f in os.listdir(folder) if f.startswith('adlc-') and f.endswith('.yml'))
    except OSError:
        return []
    out = []
    for fname in files:
        try:
            with open(os.path.join(folder, fname), encoding='utf-8') as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        current = None
        for line in lines:
            if line.lstrip().startswith('#'):
                continue
            m = LANE_AGENT_RE.match(line)
            if m:
                current = m.group(1)
                continue
            m = LANE_TOOLS_RE.search(line)
            if m:
                if current == agent:
                    out.append({'lane': fname[len('adlc-'):-len('.yml')], 'tools': _split_tools(m.group(1))})
                current = None
    return out


def _split_tools(value):
    """'Read, Bash(gh pr view:*), Edit(docs/**)' -> ['Read', 'gh pr view', 'Edit(docs/**)']."""
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
