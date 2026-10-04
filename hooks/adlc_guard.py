#!/usr/bin/env python3
"""ADLC guard — the logic behind the plugin's PreToolUse(Bash) hook (hooks/hooks.json).

Run through hooks/adlc-guard.sh, which decides scope. Reads the hook input JSON on STDIN.
Exit 2 blocks the tool call (STDERR is shown to the agent); exit 0 leaves the call to the
normal permission flow. A PreToolUse block holds in every permission mode, bypass included.

Blocked for every session in scope (charter §2 — no agent merges, pushes to main, or
force-pushes):
  * `gh pr merge`, any non-GET `gh api` call, a write to the GitHub API through curl/wget
  * a push whose destination is a protected branch — main, master, the repo's default branch
    (from the Actions event or the clone's origin/HEAD), or a name in $ADLC_PROTECTED_BRANCHES
    (comma- or space-separated) — or a destination the guard cannot name
  * a force-push, and a push of every branch (--all / --mirror / the `:` refspec)

Blocked per role (ROLE_RULES): for the three roles whose gh/git surface is deliberately
narrow, any gh or git subcommand outside the role's list. Agent `tools:` frontmatter takes
tool NAMES only, so these per-command limits live here.

The command is parsed (quotes, heredocs, $(...), subshells, `sh -c '...'`), so flag order, a
compound command, or a wrapper does not hide a call, and text inside a quoted comment body is
not mistaken for one. Within one command it follows `cd`, the git commands that change the
checked-out branch, `gh pr checkout`, and `NAME=literal` assignments, so a push is judged by
the branch it would really leave from. A step that may have failed (a checkout followed by
`;` rather than `&&`) counts both ways.

It reads command TEXT. A script written to disk, or code handed to an interpreter
(`python -c`, `node -e`), is invisible to it. This is a guardrail, not a sandbox — the hard
gate stays server-side (branch protection or the tripwire) and with the human Gate 2.
"""
import json
import os
import re
import subprocess
import sys

DEFAULT_PROTECTED = ("main", "master")

READ_GIT = {
    "status", "diff", "log", "show", "ls-files", "ls-tree", "rev-parse", "rev-list", "blame",
    "grep", "merge-base", "describe", "cat-file", "shortlog", "branch", "remote",
}
# Harmless lookups every narrow role keeps (an agent checks these when gh misbehaves).
READ_GH = {"auth": {"status"}, "repo": {"view"}, "version": None, "help": None}
# role -> the gh command groups it may use (None = every subcommand of that group) and the
# git subcommands it may use. Roles not listed (builder, qa-release-ops, the main thread) get
# the universal blocks only.
ROLE_RULES = {
    "product-analyst": {
        "gh": dict(READ_GH, issue={"view", "comment", "edit", "list", "status"}, label={"list"},
                   search=None),
        "git": READ_GIT,
    },
    "architect": {
        "gh": dict(
            READ_GH,
            issue={"view", "comment", "edit", "list", "status"},
            pr={"view", "diff", "comment", "review", "list", "checks", "status"},
        ),
        "git": READ_GIT,
    },
    "adversarial-reviewer": {
        "gh": dict(READ_GH, pr={"view", "diff", "comment", "list", "checks"}, issue={"view"}),
        "git": READ_GIT,
    },
}

PREFIX_KEYWORDS = {"if", "then", "elif", "else", "while", "until", "do", "!", "coproc"}
DECLARERS = {"export", "local", "declare", "typeset", "readonly"}
# Programs that run their arguments as a command -> the short options that take a value.
WRAPPERS = {
    "env": "uC", "command": "", "builtin": "", "exec": "a", "nohup": "", "time": "fo",
    "nice": "n", "ionice": "cnp", "timeout": "sk", "stdbuf": "ioe", "sudo": "ughpUCDRTrt",
    "doas": "uC", "xargs": "InPLdEsa", "noglob": "", "nocorrect": "", "caffeinate": "tw",
    "setsid": "", "flock": "wE", "watch": "n", "chronic": "", "unbuffer": "",
}
LONG_VALUE_FLAGS = {
    "--user", "--group", "--host", "--prompt", "--signal", "--kill-after", "--max-args",
    "--max-procs", "--delimiter", "--arg-file", "--unset", "--chdir", "--adjustment",
    "--interval", "--timeout",
}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "ash", "fish"}
FORCE_OPTS = ("--force", "--force-with-lease", "--force-if-includes")
EVERY_BRANCH_OPTS = ("--all", "--mirror", "--branches")
BRANCH_LIST_OPTS = ("-l", "--list", "--contains", "--no-contains", "--merged", "--no-merged",
                    "--points-at")
BRANCH_WRITE_OPTS = ("-d", "-D", "-m", "-M", "-c", "-C", "-f", "-u", "-t", "--delete", "--move",
                     "--copy", "--force", "--track", "--unset-upstream", "--edit-description")
REBASE_VALUE_OPTS = ("--onto", "-s", "--strategy", "-X", "--strategy-option", "-x", "--exec")
CURL_VALUE_FLAGS = "AbcCeEHKmoPQrtuwxyYz"  # curl short options whose value follows
# curl/wget options whose value is often a variable (a token header, an output file)
HTTP_VALUE_OPTS = {"-H", "--header", "-o", "--output", "-O", "--output-document", "-u", "--user",
                   "-A", "--user-agent", "-w", "--write-out", "-m", "--max-time", "--retry"}
EXPANSIONS = ("$", "`…`", "<(…)")  # how a word starts when the shell computes its beginning
MOVES_HEAD = {"checkout", "switch", "branch", "rebase", "stash", "symbolic-ref"}
ROUTES_PUSH = ("push.", "remote.", "branch.", "url.")  # config sections that decide where a push goes
PUSHES = ("push", "send-pack", "http-push")  # git subcommands that update a remote's refs
XARGS_INPUT = "$ARGS_FROM_XARGS"  # stands for the arguments xargs appends, which nobody can read here
PR_BRANCH = "\0pr"  # `gh pr checkout` left the repo on a PR's head branch — never the base

ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
VAR_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-]")
VAR_REF = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))")
DURATION = re.compile(r"^\d+(\.\d+)?[smhd]?$")
HEREDOC_ESCAPE = re.compile(r"\\([$`\\])")
ANSI_C = re.compile(r"\\(x[0-9A-Fa-f]{1,2}|u[0-9A-Fa-f]{1,4}|[0-7]{1,3}|.)", re.S)
ANSI_C_NAMED = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "e": "\x1b", "f": "\f", "v": "\v"}
RAW_PUSH = re.compile(r"(?<![\w.-])git\b(?:\s+-[cC]\s*\S+|\s+--?[\w-]+(?:=\S+)?)*\s+['\"]?push\b")
RAW_MERGE = re.compile(r"(?<![\w.-])gh\b[^\n;|&]*?\bpr\s+merge\b")
RAW_API = re.compile(r"(?<![\w.-])gh\b[^\n;|&]*?\bapi\b")
RAW_HTTP = re.compile(r"^(?=.*(?<![\w.-])(?:curl|wget)\b)(?=.*(?:(?:api|uploads)\.github\.com|GITHUB_(?:API|GRAPHQL)_URL))",
                      re.I | re.M)  # one line naming both, in either order
MAX_DEPTH = 12


def ansi_c(text):
    """The string a $'…' literal stands for."""
    def one(m):
        e = m.group(1)
        if e[0] in "xu" and len(e) > 1:
            return chr(int(e[1:], 16))
        if e[0] in "01234567":
            return chr(int(e, 8))
        return ANSI_C_NAMED.get(e, e)
    return ANSI_C.sub(one, text)


class Block(Exception):
    """Raised with the message the agent should read."""


class ParseError(Exception):
    pass


class Word:
    __slots__ = ("parts", "dynamic", "splits", "text")

    def __init__(self, text="", dynamic=False):
        self.parts = [text] if text else []
        self.dynamic = dynamic  # holds an expansion ($VAR, $(...), `...`) not resolved yet
        self.splits = False  # … an unquoted one, which the shell may split into several words
        self.text = text

    def add(self, piece):
        self.parts.append(piece)

    def peek(self):
        return "".join(self.parts)


class Cmd:
    __slots__ = ("words", "heredocs", "sep", "pipe_out", "scope", "embedded", "array", "fed", "fresh",
                 "nested", "background")

    def __init__(self, scope, embedded, array, sep):
        self.words = []
        self.heredocs = []  # (text, quoted) fed on stdin by << or <<<
        self.sep = sep  # the operator before this command: "" ";" "&&" "||" "|" "&"
        self.pipe_out = False
        self.background = False  # ended by `&`: it runs in a subshell of its own
        self.scope = scope  # subshell nesting — a `cd` inside one does not leave it
        self.embedded = embedded  # sits in $(...) or `...` inside a double-quoted string
        self.array = array  # the words of an x=( ... ) literal: data, not a command
        self.fed = False  # a redirection reads from <(…): input nobody can read here
        self.fresh = False  # follows a group that may not have run (`a || { … } && this`)
        self.nested = False  # sits in a { … } group or a case arm, which may itself not run


class Parser:
    """Splits shell text into simple commands, nested ones included. Enough bash to tell
    code from data: quoting, expansions, heredocs, redirections, subshells, the operators
    that end a command. Unknown syntax degrades to plain words rather than failing."""

    def __init__(self, src, depth=0, scope=(), embedded=False, ids=None):
        self.s = src
        self.n = len(src)
        self.i = 0
        self.cmds = []
        self.funcs = set()  # names this text defines as shell functions
        self.depth = depth
        self.scope = scope  # scope of the command being read
        self.embedded = embedded
        self.in_dq = False
        self.ids = ids if ids is not None else [0]

    def new_scope(self, parent, substitution=False):
        """A fresh scope id under `parent`; a $(…), `…` or <(…) gets a negative one."""
        self.ids[0] += 1
        return parent + (-self.ids[0] if substitution else self.ids[0],)

    def parse(self, stop=None):
        """Parse to the end of input, or to an unmatched `stop` char. True if `stop` was hit."""
        s, n = self.s, self.n
        st = {"word": None, "drop": False, "herestring": False, "sep": "", "parens": 0,
              "arrays": 0, "cases": [], "test": False, "func": False, "braces": [],
              "groups": [], "fresh": False, "list": len(self.cmds), "lists": [], "compounds": []}
        scopes = [self.scope]
        pending = []  # heredocs whose body starts after the next newline

        def new_cmd():
            return Cmd(scopes[-1], self.embedded, st["arrays"] > 0, st["sep"])

        st["cur"] = new_cmd()

        def w():
            if st["word"] is None:
                st["word"] = Word()
            return st["word"]

        def end_word():
            word = st["word"]
            if word is None:
                return
            st["word"] = None
            word.text = word.peek()
            cur = st["cur"]
            if st["herestring"]:
                st["herestring"] = False
                cur.heredocs.append((word.text, True))
            elif st["drop"]:
                st["drop"] = False
                cur.fed = cur.fed or "<(…)" in word.text
            else:
                cur.words.append(word)
                plain = not word.dynamic and not cur.array
                if plain and word.text == "[[" and all(x.text in PREFIX_KEYWORDS for x in cur.words[:-1]):
                    st["test"] = True  # [[ … ]]: `(`, `|`, `<` in there are part of the test
                elif plain and word.text == "]]":
                    st["test"] = False

        def end_cmd(sep=";"):
            end_word()
            st["drop"] = False
            st["test"] = False
            cur = st["cur"]
            if cur.words or cur.heredocs:
                cur.pipe_out = sep == "|"
                cur.fresh, st["fresh"] = st["fresh"], False
                cur.nested = bool(st["braces"] or st["cases"])
                first = cur.words[0] if cur.words else None
                if first is not None and not first.dynamic and not cur.array:
                    if first.text == "case":
                        st["cases"].append(st["parens"])
                    elif first.text == "esac" and st["cases"]:
                        st["cases"].pop()
                    elif first.text == "function" and len(cur.words) > 1:
                        self.funcs.add(cur.words[1].text)
                        st["func"] = True
                self.cmds.append(cur)
                # The `;` inside `if …; then …; fi` (while/for/case alike) do not end the list
                # the compound sits in: remember where that list began, and come back to it.
                for word in cur.words:
                    if word.dynamic or cur.array:
                        break
                    if word.text in ("if", "while", "until", "for", "select", "case"):
                        st["compounds"].append(st["list"])
                    elif word.text in ("fi", "done", "esac") and st["compounds"]:
                        st["list"] = st["compounds"].pop()
                    elif word.text not in PREFIX_KEYWORDS:
                        break
            if sep == "&":  # `a && b &` puts the whole list in a background subshell
                for job in self.cmds[st["list"]:]:
                    job.background = True
            if sep not in ("&&", "||", "|"):
                st["list"] = len(self.cmds)
            st["sep"] = sep
            st["cur"] = new_cmd()

        def skippable():
            """Is the group about to open one that may not run, or whose failure lets the
            list go on — the right side of `||`, or behind `!` / `coproc`?"""
            return st["sep"] == "||" or any(
                not x.dynamic and x.text in ("!", "coproc") for x in st["cur"].words)

        def enter(scope):
            scopes.append(scope)
            self.scope = scope
            st["cur"] = new_cmd()

        def leave():
            scopes.pop()
            self.scope = scopes[-1]
            st["cur"] = new_cmd()

        while self.i < n:
            c = s[self.i]
            nxt = s[self.i + 1] if self.i + 1 < n else ""
            if c == "\\":
                if nxt == "\n":
                    self.i += 2
                    continue
                w().add(nxt)
                self.i += 2
            elif c == "'":
                j = s.find("'", self.i + 1)
                if j == -1:
                    raise ParseError("unterminated '")
                w().add(s[self.i + 1:j])
                self.i = j + 1
            elif c == '"':
                self._dquote(w())
            elif c == "$":
                self._dollar(w(), unquoted=True)
            elif c == "`":
                self._backtick(w(), unquoted=True)
            elif c in " \t\r":
                end_word()
                self.i += 1
            elif c == "\n":
                end_cmd()
                self.i += 1
                for delim, strip, quoted, cmd in pending:
                    body = self._heredoc_body(delim, strip, stop)
                    cmd.heredocs.append((body, quoted))
                    if not quoted:
                        self._scan_expansions(body)
                pending = []
            elif c == "#" and st["word"] is None:
                j = s.find("\n", self.i)
                self.i = n if j == -1 else j
            elif st["test"] and c in ";&|<>(){}":
                w().add(c)
                self.i += 1
            elif c == ";":
                end_cmd()
                self.i += 1
                while self.i < n and s[self.i] in ";&":
                    self.i += 1
            elif c == "&":
                if nxt == ">":  # &> file — a redirection, handled by the next iteration
                    self.i += 1
                else:
                    end_cmd("&&" if nxt == "&" else "&")
                    self.i += 2 if nxt == "&" else 1
            elif c == "|":
                if nxt == "|":
                    end_cmd("||")
                    self.i += 2
                else:
                    end_cmd("|")
                    self.i += 2 if nxt == "&" else 1
            elif c in "<>":
                word = st["word"]
                if word is not None and "[" in word.peek() and "]" not in word.peek().rsplit("[", 1)[1]:
                    word.add(c)  # arr[1<<2]=x — inside an index this is arithmetic
                    self.i += 1
                    continue
                if word is not None and not word.dynamic and word.peek().isdigit():
                    st["word"] = None  # the fd number glued to the operator
                if s.startswith("<<<", self.i):
                    end_word()
                    self.i += 3
                    st["herestring"] = True
                elif s.startswith("<<", self.i):
                    end_word()
                    pending.append(self._heredoc_delim() + (st["cur"],))
                elif nxt == "(":  # <(...) or >(...) process substitution
                    self.i += 2
                    self._nested(")")
                    w().add("<(…)")
                    w().dynamic = True
                else:
                    end_word()
                    self.i += 1
                    while self.i < n and s[self.i] in ">|&":
                        self.i += 1
                    st["drop"] = True  # the redirection target is not an argument
            elif c == "(":
                word, cur = st["word"], st["cur"]
                if word is not None and not word.dynamic and word.peek() == "=":
                    self.i += 1  # zsh's =(…): a process substitution, like <(…)
                    self._nested(")")
                    word.parts = ["<(…)"]
                    word.dynamic = True
                elif word is not None and word.peek().endswith("="):
                    st["word"] = None  # x=( … ): the elements are data; a $(…) in them still runs
                    end_cmd()
                    st["arrays"] += 1
                    st["cur"] = new_cmd()
                    self.i += 1
                elif nxt == ")" and (word is not None or len(cur.words) == 1):
                    end_word()  # name() — a function definition; its body follows
                    if st["cur"].words:
                        self.funcs.add(st["cur"].words[-1].text)
                    end_cmd()
                    st["func"] = True
                    self.i += 2
                elif nxt == "(" and word is None and self._arith_end(self.i) != -1 and all(
                        x.text in ("for", "time") or x.text in PREFIX_KEYWORDS for x in cur.words):
                    j = self._arith_end(self.i)  # (( arithmetic )): `<<` in here is a shift
                    self._scan_expansions(s[self.i + 2:j - 1])
                    end_cmd()
                    self.i = j + 1
                else:
                    st["groups"].append(skippable())
                    st["lists"].append(st["list"])
                    end_cmd()
                    st["parens"] += 1
                    st["func"] = False
                    enter(self.new_scope(scopes[-1]))
                    self.i += 1
            elif c == ")":
                end_word()
                self.i += 1
                cur = st["cur"]
                first = cur.words[0].text if cur.words and not cur.words[0].dynamic else None
                if first == "esac":  # `esac)` — the case statement ends before this paren
                    end_cmd()
                    first = None
                if st["arrays"]:
                    end_cmd()
                    st["arrays"] -= 1
                    st["cur"] = new_cmd()
                elif first == "case" or (st["cases"] and st["cases"][-1] == st["parens"]):
                    end_cmd()  # closes a case pattern, not a subshell or a substitution
                elif st["parens"]:
                    end_cmd()
                    st["parens"] -= 1
                    leave()
                    st["fresh"] = st["groups"].pop() if st["groups"] else False
                    st["list"] = st["lists"].pop() if st["lists"] else st["list"]
                else:
                    end_cmd()
                    if stop == ")":
                        return True
            elif c in "{}" and st["word"] is None and (nxt == "" or nxt in " \t\n;&|)"):
                maybe, outer = c == "{" and skippable(), st["list"]
                end_cmd()  # a brace group `{ …; }` — its body is ordinary commands
                self.i += 1
                if c == "{":
                    st["braces"].append((st["func"], maybe, outer))
                    if st["func"]:  # a function BODY: defining it runs nothing, moves nowhere
                        st["func"] = False
                        enter(self.new_scope(scopes[-1]))
                elif st["braces"]:
                    body, maybe, outer = st["braces"].pop()
                    if body and len(scopes) > 1:
                        leave()
                    st["fresh"], st["list"] = maybe, outer
            else:
                w().add(c)
                self.i += 1
        end_cmd()
        for delim, strip, quoted, cmd in pending:  # heredoc opened on the last line
            cmd.heredocs.append(("", quoted))
        return False

    def _nested(self, stop):
        if self.depth >= MAX_DEPTH:
            raise ParseError("nesting too deep")
        saved = (self.scope, self.embedded, self.in_dq)
        self.scope = self.new_scope(self.scope, substitution=True)
        self.embedded = self.embedded or self.in_dq
        self.in_dq = False
        self.depth += 1
        found = self.parse(stop)
        self.depth -= 1
        self.scope, self.embedded, self.in_dq = saved
        if not found:
            raise ParseError("unterminated substitution")

    def _dquote(self, word):
        s, n = self.s, self.n
        outer, self.in_dq = self.in_dq, True
        self.i += 1
        while self.i < n:
            c = s[self.i]
            if c == '"':
                self.i += 1
                self.in_dq = outer
                return
            if c == "\\" and self.i + 1 < n:
                nxt = s[self.i + 1]
                if nxt in '"\\$`':
                    word.add(nxt)
                elif nxt != "\n":
                    word.add("\\" + nxt)
                self.i += 2
            elif c == "$":
                self._dollar(word)
            elif c == "`":
                self._backtick(word)
            else:
                word.add(c)
                self.i += 1
        raise ParseError('unterminated "')

    def _dollar(self, word, unquoted=False):
        s, n, i = self.s, self.n, self.i
        if s.startswith("$'", i) and not self.in_dq:  # ANSI-C quoting: data
            j = i + 2
            while j < n and s[j] != "'":
                j += 2 if s[j] == "\\" else 1
            if j >= n:
                raise ParseError("unterminated $'")
            word.add(ansi_c(s[i + 2:j]))
            self.i = j + 1
            return
        if s.startswith('$"', i) and not self.in_dq:  # $"…": a translated string
            self.i = i + 1
            return
        if s.startswith("$((", i) and self._arith_end(i + 1) != -1:
            j = self._arith_end(i + 1)  # $(( arithmetic )) — a $(…) inside it still runs
            self._scan_expansions(s[i + 3:j - 1])
            word.add(s[i:j + 1])
            self.i = j + 1
        elif s.startswith("$(", i):
            self.i = i + 2
            self._nested(")")
            word.add("$(…)")
        elif s.startswith("$[", i):  # $[ arithmetic ], the old spelling
            j = s.find("]", i + 2)
            if j == -1:
                raise ParseError("unterminated $[")
            self._scan_expansions(s[i + 2:j])
            word.add(s[i:j + 1])
            self.i = j + 1
        elif s.startswith("${", i):
            self._braces(word)
        else:
            m = VAR_NAME.match(s, i + 1)
            if not m:
                word.add("$")
                self.i = i + 1
                return
            word.add(s[i:m.end()])
            self.i = m.end()
        word.dynamic = True
        word.splits = word.splits or unquoted

    def _braces(self, word):
        """Read ${ … } from the `$` at self.i. A $(…), `…` or "…" nested in it is parsed."""
        s, n, start = self.s, self.n, self.i
        sink = Word()
        self.i += 2
        while self.i < n:
            c = s[self.i]
            if c == "}":
                self.i += 1
                word.add(s[start:self.i])
                return
            if c == "\\":
                self.i += 2
            elif c == "$":
                self._dollar(sink)
            elif c == "`":
                self._backtick(sink)
            elif c == '"':
                self._dquote(sink)
            elif c == "'" and not self.in_dq:  # inside "…" an apostrophe is just a character
                j = s.find("'", self.i + 1)
                if j == -1:
                    break
                self.i = j + 1
            else:
                self.i += 1
        raise ParseError("unterminated ${")

    def _arith_end(self, i):
        """s[i:i+2] is "((". Index of its last ")" when this is (( arithmetic )), else -1:
        `((a); b)` is two subshells, and bash tells the two apart the same way."""
        s, n = self.s, self.n
        opens, inner, j = [], -1, i
        while j < n:
            c = s[j]
            if c == "\\":
                j += 2
                continue
            if c in "'\"":
                j = s.find(c, j + 1)
                if j == -1:
                    return -1
            elif c == "(":
                opens.append(j)
            elif c == ")":
                start = opens.pop()
                if start == i + 1:
                    inner = j
                elif start == i:
                    return j if inner == j - 1 else -1
            j += 1
        return -1

    def _backtick(self, word, unquoted=False):
        s, n = self.s, self.n
        j = self.i + 1
        while j < n and s[j] != "`":
            j += 2 if s[j] == "\\" else 1
        if j >= n:
            raise ParseError("unterminated `")
        self._sub(s[self.i + 1:j].replace("\\`", "`"))
        word.add("`…`")
        word.dynamic = True
        word.splits = word.splits or unquoted
        self.i = j + 1

    def _child(self, text):
        if self.depth >= MAX_DEPTH:
            raise ParseError("nesting too deep")
        return Parser(text, self.depth + 1, self.new_scope(self.scope, substitution=True),
                      self.embedded or self.in_dq, self.ids)

    def _sub(self, text):
        """Parse text that is code in its own right (a `...` body) and keep its commands."""
        sub = self._child(text)
        sub.parse()
        self.cmds.extend(sub.cmds)
        self.funcs |= sub.funcs

    def _scan_expansions(self, text):
        """Find $(...) and `...` inside text that is otherwise data (an unquoted heredoc)."""
        if self.depth >= MAX_DEPTH or ("$" not in text and "`" not in text):
            return
        sub = self._child(text)
        sub.in_dq = True  # as in "…": quotes are literal here, only expansions are live
        sink = Word()
        try:
            while sub.i < sub.n:
                c = sub.s[sub.i]
                if c == "\\":
                    sub.i += 2
                elif c == "$":
                    sub._dollar(sink)
                elif c == "`":
                    sub._backtick(sink)
                else:
                    sub.i += 1
        except ParseError:
            pass  # stray "$(" in prose — whatever parsed before it still counts
        self.cmds.extend(sub.cmds)
        self.funcs |= sub.funcs

    def _heredoc_delim(self):
        s, n = self.s, self.n
        self.i += 2
        strip = self.i < n and s[self.i] == "-"
        if strip:
            self.i += 1
        while self.i < n and s[self.i] in " \t":
            self.i += 1
        delim, quoted = "", False
        while self.i < n and s[self.i] not in " \t\n;&|<>()":
            c = s[self.i]
            if c in "'\"":
                j = s.find(c, self.i + 1)
                if j == -1:
                    raise ParseError("unterminated heredoc delimiter")
                delim += s[self.i + 1:j]
                quoted = True
                self.i = j + 1
            elif c == "\\":
                delim += s[self.i + 1:self.i + 2]
                quoted = True
                self.i += 2
            else:
                delim += c
                self.i += 1
        return delim, strip, quoted

    def _heredoc_body(self, delim, strip, stop):
        s, n = self.s, self.n
        lines = []
        while self.i < n:
            j = s.find("\n", self.i)
            line = s[self.i:] if j == -1 else s[self.i:j]
            seen = line.lstrip("\t") if strip else line
            if seen == delim:
                self.i = n if j == -1 else j + 1
                return "\n".join(lines)
            if stop == ")" and seen.startswith(delim) and seen[len(delim):].lstrip().startswith(")"):
                # `EOF)` closing $(cat <<EOF ... EOF) on one line — leave the ")" to the caller
                self.i += len(line) - len(seen) + len(delim)
                return "\n".join(lines)
            lines.append(line)
            self.i = n if j == -1 else j + 1
        return "\n".join(lines)


def base(word):
    return os.path.basename(word.text)


def git_out(repo, *args):
    try:
        r = subprocess.run(["git", "-C", repo] + list(args), stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, universal_newlines=True, timeout=5)
    except Exception:  # no git, no such directory, a hung call — all mean "unknown"
        return None
    out = r.stdout.strip()
    return out if r.returncode == 0 and out else None


class Guard:
    def __init__(self, role, cwd, raw):
        self.role = role if role in ROLE_RULES else None
        self.home = cwd  # where the session is when the hook fires
        self.cwds = {(): cwd}  # shell scope -> its cwd; None once a `cd` can't be followed
        self.maybe = {}  # scope -> the &&-chain of its last `cd`, if that ran only on a condition
        # repo -> (branch a step of THIS command leaves it on, every branch it may be on if that
        # step or an earlier one failed, the &&-chain the step belongs to). A later push in the
        # same chain knows the step succeeded; past a `;` it may not have.
        self.moves = {}
        # Set once a step may have moved HEAD where the guard can't follow: in a repo it can't
        # name, in a shell function, or in text it can't read. No branch is trusted after that.
        self.lost = False
        self.later = 0  # > 0 while checking code that runs at some other time (a trap)
        self.unsure = 0  # > 0 while checking `eval`/`source` text whose command ran on a condition
        self.starts = {}  # repo -> the start point a branch created in this command tracks
        self.tops = {}  # directory -> its repository's top level
        self.vars = {}  # NAME -> the literal an earlier assignment in this command gave it
        self.funcs = set()
        self.chain = 0
        # Literal DATA seen so far: variable values, array elements, and the arguments and stdin
        # of ordinary programs. When the command runs text it computes (eval "$X", `echo … | sh`),
        # this is what that text could have been built from.
        self.data = []
        self.pending = []  # opaque constructs seen, checked once all the data is collected
        self.ids = [0]

    def cwd_of(self, scope):
        for k in range(len(scope), -1, -1):
            if scope[:k] in self.cwds:
                return self.cwds[scope[:k]]
        return None

    def child_scope(self, scope):
        self.ids[0] += 1
        return scope + (self.ids[0],)

    def top(self, repo):
        """The repository a directory belongs to: `cd src` and `git -C src` name the same one."""
        if not repo:
            return repo
        if repo not in self.tops:
            self.tops[repo] = git_out(repo, "rev-parse", "--show-toplevel") or repo
        return self.tops[repo]

    # -- entry points ------------------------------------------------------------------
    def check_text(self, text, depth=0, scope=()):
        if depth > MAX_DEPTH:
            raise Block("the command nests too deeply to verify. Simplify it.")
        try:
            parser = Parser(text, ids=self.ids)
            parser.parse()
        except ParseError:
            if self.role:
                raise Block("this command could not be parsed, so the %s role's limits can't be "
                            "checked. Simplify it." % self.role)
            self.raw_scan(text, "a command the guard could not parse")
            return
        self.funcs |= parser.funcs
        before = None  # the substitutions the command before this one sat in
        for cmd in parser.cmds:
            if cmd.array:
                self.data.append(" ".join(word.text for word in cmd.words))
                continue
            at = scope + cmd.scope
            # An &&-chain is consecutive commands joined by `&&`: reaching the next one proves
            # the one before it succeeded. Not across a $(…): its status is not the status of
            # the command it is an argument of (`echo $(git checkout -b x) && …` goes on).
            inside = tuple(i for i in cmd.scope if i < 0)
            if cmd.sep != "&&" or inside != before or cmd.fresh:
                self.chain += 1
            for k in range(len(at) + 1):  # a conditional `cd`, here or in an enclosing scope,
                if self.maybe.get(at[:k], self.chain) != self.chain:  # may not have run
                    del self.maybe[at[:k]]
                    self.cwds[at[:k]] = None
            before = inside
            try:
                self.check_cmd(cmd.words, cmd, depth, at)
            except Block as b:
                if not cmd.embedded:
                    raise
                raise Block("%s (This call sits inside `…` or $(…) in a double-quoted string, "
                            "which the shell would run. To quote it as text, use single quotes "
                            "or a <<'EOF' heredoc.)" % b)
            # What follows with `&&` does NOT prove this command ran and succeeded when it
            # sits after `||` (`a || step && …` goes on when `a` succeeded), is negated
            # (`! step && …` goes on when the step FAILED), or is a coproc (nobody waits).
            if cmd.sep == "||":
                self.chain += 1
            for word in cmd.words:
                if word.dynamic or word.text not in PREFIX_KEYWORDS:
                    break
                if word.text in ("!", "coproc"):
                    self.chain += 1
        if depth == 0:  # data defined after its use counts too (`while read c; do $c; done <<EOF`)
            for what, extra, prefix in self.pending:
                lines = self.data + [extra]
                if prefix:  # `… | xargs curl`: each piece of data may be that program's arguments
                    lines += [prefix + " " + " ".join(d.split()) for d in self.data]
                self.raw_scan("\n".join(lines), "text this command hands to " + what)

    def raw_scan(self, text, where):
        """Fallback for code the guard can't see into: block on any textual hit."""
        for rx, what in ((RAW_MERGE, "`gh pr merge`"), (RAW_PUSH, "`git push`"), (RAW_API, "`gh api`"),
                         (RAW_HTTP, "a curl/wget call to the GitHub API")):
            if rx.search(text):
                raise Block(
                    "%s appears in %s, where its target can't be verified. Run it as a "
                    "plain command of its own." % (what, where)
                )

    def opaque(self, what, extra="", moves=True, prefix=""):
        """The command runs text it computes. Its literal data is checked once all of it is
        known, at the end of check_text — and that text may switch branches unseen."""
        self.pending.append((what, extra, prefix))
        self.lost = self.lost or moves

    def deferred(self, word, depth, scope, what):
        """Code the shell keeps and runs later (a trap): checked now, on an unknown branch."""
        if word.dynamic:
            self.opaque(what)
        self.later += 1
        try:
            self.check_text(word.text, depth + 1, self.child_scope(scope))
        finally:
            self.later -= 1
            self.chain += 1  # … so no later step may rely on what it does

    def resolve(self, words):
        """Replace $NAME with the literal an earlier `NAME=…` in this command gave it."""
        out = []
        for word in words:
            if not word.dynamic or "$" not in word.text:
                out.append(word)
                continue
            text = VAR_REF.sub(lambda m: self.vars.get(m.group(1) or m.group(2), m.group(0)), word.text)
            if "$" in text or "`…`" in text or "<(…)" in text:
                out.append(word)  # something in it is still unknown
            elif word.splits:
                out.extend(Word(piece) for piece in text.split())
            else:
                out.append(Word(text))
        return out

    def assign(self, word):
        name, value = word.text.split("=", 1)
        append = name.endswith("+")
        name = name.rstrip("+")
        if word.dynamic or (append and name not in self.vars):
            self.vars.pop(name, None)
        else:
            self.vars[name] = (self.vars[name] if append else "") + value

    # -- one simple command --------------------------------------------------------------
    def check_cmd(self, words, cmd, depth, scope, external=False):
        """`external`: a program runs these words (env, xargs, find -exec …), not this shell —
        a `cd` among them changes nothing here."""
        words = self.resolve(words)
        conditional = cmd.sep in ("&&", "||")
        while words and not words[0].dynamic and words[0].text in PREFIX_KEYWORDS:
            conditional = True
            words.pop(0)
        env = []
        while words and ASSIGNMENT.match(words[0].text):
            env.append(words.pop(0))
        for word in env:
            self.data.append(word.text.split("=", 1)[1])
        if not words:
            for word in env:  # `NAME=value` on its own sets a shell variable
                self.assign(word)
            return
        names = [word.text.split("=", 1)[0].rstrip("+") for word in env]
        head, args = words[0], words[1:]
        prog = base(head)

        if head.dynamic and any(mark in head.text.rsplit("/", 1)[-1] for mark in EXPANSIONS):
            # The program's NAME is computed ("$GIT", $(command -v gh)): it may be git, gh or
            # curl. ("$HOME/bin/gh" is not this case: its last part is literal, so it is gh.)
            if self.role:
                raise Block("a command whose program name is computed (`%s`) can't be checked "
                            "against the %s role's limits. Write the program name out."
                            % (head.text, self.role))
            texts = [a.text for a in args]
            self.opaque("a command whose name is computed", " ".join(texts),
                        moves=any(t in MOVES_HEAD or t.lower().startswith(ROUTES_PUSH) for t in texts))
            # Judge it as the call its arguments make it look like: "$GIT" push …,
            # "$GH" pr merge …, "$GH" api -X DELETE …, "$CURL" -X PUT https://api.github.com/…
            try:
                for word in PUSHES:
                    if word in texts:
                        self.check_push(args[texts.index(word) + 1:], self.cwd_of(scope), plumbing=word != "push")
                for word in ("pr", "api", "alias"):
                    if word in texts:
                        self.check_gh(args[texts.index(word):], scope)
                self.check_http("curl", args)
            except Block as b:
                raise Block("%s (The program here is named by `%s`, so the command is judged as the "
                            "git, gh or curl call it may be. If it is another program, write its "
                            "name out.)" % (b, head.text))
        elif prog in ("cd", "pushd"):
            if external or cmd.sep == "|" or cmd.pipe_out or cmd.background:
                return  # another program, a pipeline element or a `&` job: its cd goes nowhere
            target = next((a for a in args if not a.text.startswith("-") or a.text == "-"), None)
            here = self.cwd_of(scope)
            path = None if target is None or target.dynamic else os.path.expanduser(target.text)
            if path is None or path == "-" or (here is None and not os.path.isabs(path)):
                self.cwds[scope] = None
            else:  # an absolute path is known wherever the shell was
                self.cwds[scope] = os.path.normpath(os.path.join(here or "/", path))
            if conditional or cmd.nested or self.unsure:  # trusted only by what its own &&-chain reaches
                self.maybe[scope] = self.chain
            else:
                self.maybe.pop(scope, None)
        elif prog == "popd":
            if not external:
                self.cwds[scope] = None
        elif prog in self.funcs or prog == "function":
            # A helper defined in this command (`retry gh pr merge 5`), or its definition. Its
            # body runs whenever it is called, so from here on the directory is unknown — and a
            # branch move in that body, made from an unknown directory, marks HEAD as lost.
            self.cwds[scope] = None
            self.data.append(" ".join(a.text for a in args))
            if args and prog != "function":
                self.check_cmd(args, cmd, depth + 1, scope)
        elif prog in DECLARERS:
            for a in args:
                if ASSIGNMENT.match(a.text):
                    self.assign(a)
        elif prog == "for" and len(args) >= 2 and args[1].text == "in":
            values = args[2:]  # a loop over one literal is that literal; anything else is unknown
            self.vars.pop(args[0].text, None)
            if len(values) == 1 and not values[0].dynamic:
                self.vars[args[0].text] = values[0].text
        elif prog == "read":
            for a in args:
                self.vars.pop(a.text, None)
        elif prog in WRAPPERS:
            self.check_wrapped(prog, args, cmd, depth, scope)
        elif prog in SHELLS:
            self.check_shell(args, cmd, depth, scope)
        elif prog in ("eval", "source", "."):
            self.unsure += conditional or cmd.nested
            try:
                if prog != "eval":
                    self.check_shell(args, cmd, depth, self.same_shell(cmd, scope, external), dash_c=False)
                else:
                    if any(a.dynamic for a in args):
                        self.opaque("`eval`")
                    self.check_text(" ".join(a.text for a in args), depth + 1,
                                    self.same_shell(cmd, scope, external))
            finally:
                self.unsure -= conditional or cmd.nested
        elif prog == "trap":  # trap '<code>' SIGNAL… — the code runs when the signal comes
            operands = [a for a in args if a.text == "-" or not a.text.startswith("-")]
            if len(operands) > 1 and operands[0].text not in ("-", ""):
                self.deferred(operands[0], depth, scope, "`trap`")
        elif prog == "find":
            for k, a in enumerate(args):
                if a.text in ("-exec", "-execdir", "-ok", "-okdir"):
                    sub = []
                    for b in args[k + 1:]:
                        if b.text in (";", "+"):
                            break
                        sub.append(b)
                    self.check_cmd(sub, cmd, depth + 1, scope, external=True)
                    self.chain += 1  # zero matches: find succeeds and the command never ran
        elif prog == "git":
            self.check_git(args, scope, "GIT_DIR" in names or "GIT_WORK_TREE" in names)
        elif prog == "gh":
            self.check_gh(args, scope)
        elif prog in ("curl", "wget"):
            self.check_http(prog, args)
        else:
            self.data.append(" ".join(a.text for a in args))
            self.data.extend(body for body, _ in cmd.heredocs)

    def same_shell(self, cmd, scope, external):
        """The scope `eval` / `source` text runs in: this shell's, unless the command is a
        pipeline element, a `&` job or another program's argument — then a `cd` in it stays there."""
        apart = external or cmd.sep == "|" or cmd.pipe_out or cmd.background
        return self.child_scope(scope) if apart else scope

    def check_wrapped(self, prog, args, cmd, depth, scope):
        if prog == "command" and args and args[0].text in ("-v", "-V"):
            return  # a lookup, not an execution
        rest, replaces = list(args), False
        while rest:
            t = rest[0].text
            if t.startswith("-") and t != "-":
                rest.pop(0)
                replaces = replaces or t[:2] in ("-I", "-i", "-J") or t.startswith("--replace")
                if rest and ((prog == "env" and t in ("-S", "--split-string"))
                             or (prog == "flock" and t in ("-c", "--command"))):
                    self.check_text(rest[0].text, depth + 1, self.child_scope(scope))
                    return
                if rest and (t in LONG_VALUE_FLAGS or (len(t) == 2 and t[1] in WRAPPERS[prog])):
                    rest.pop(0)
            elif (prog == "timeout" and DURATION.match(t)) or (
                    prog in ("env", "sudo", "doas") and ASSIGNMENT.match(t)):
                rest.pop(0)
            else:
                break
        if prog == "flock" and rest:  # flock [options] <lockfile> <command…> | -c '<command>'
            rest.pop(0)
            if len(rest) > 1 and rest[0].text in ("-c", "--command"):
                self.check_text(rest[1].text, depth + 1, self.child_scope(scope))
                return
        if prog == "watch" and rest:  # watch hands its arguments to `sh -c` as one string
            if any(a.dynamic for a in rest):
                self.opaque("`watch`")
            self.check_text(" ".join(a.text for a in rest), depth + 1, self.child_scope(scope))
            return
        if prog == "xargs" and rest:
            if replaces:  # the input lands anywhere in the command, a `sh -c` string included
                self.opaque("`xargs` with a replacement string")
            unseen = Word(XARGS_INPUT, True)  # … or at its end: arguments nobody can read here
            unseen.splits = True
            rest.append(unseen)
        if rest:  # only the shell's own prefixes keep a `cd` in this shell
            self.check_cmd(rest, cmd, depth + 1, scope,
                           external=prog not in ("command", "builtin", "time", "noglob", "nocorrect"))
        if prog in ("xargs", "setsid"):  # ran it zero times (no input), or did not wait for it
            self.chain += 1

    def check_shell(self, args, cmd, depth, scope, dash_c=True):
        """A shell, or `source`: find the code it runs — a `-c` string, a script, or stdin."""
        for k, a in enumerate(args if dash_c else ()):
            if a.text.startswith("-") and not a.text.startswith("--") and "c" in a.text[1:]:
                if k + 1 < len(args):
                    if args[k + 1].dynamic:
                        self.opaque("a shell's `-c`")
                    self.check_text(args[k + 1].text, depth + 1, self.child_scope(scope))
                return
        if cmd.fed or any("<(…)" in a.text for a in args):
            self.opaque("a shell reading a process substitution")
        if cmd.heredocs:
            for body, quoted in cmd.heredocs:
                if not quoted:  # the outer shell undoes these escapes before the inner one reads
                    body = HEREDOC_ESCAPE.sub(r"\1", body)
                self.check_text(body, depth + 1, self.child_scope(scope) if dash_c else scope)
        elif cmd.sep == "|":
            self.opaque("a shell through a pipe")

    # -- git ---------------------------------------------------------------------------
    def check_git(self, args, scope, detached):
        repo, k, overrides = (None if detached else self.cwd_of(scope)), 0, []
        while k < len(args):
            a = args[k].text
            if a in ("--version", "-v", "--help", "-h", "--exec-path", "--html-path", "--man-path",
                     "--info-path"):
                return  # git prints that and runs no subcommand: nothing is pushed or switched
            if a.startswith("--config-env"):
                overrides.append(args[k + 1] if "=" not in a and k + 1 < len(args) else Word(a.split("=", 1)[-1]))
            if a == "-C" and k + 1 < len(args):
                d = args[k + 1]
                repo = None if (d.dynamic or repo is None) else os.path.normpath(
                    os.path.join(repo, os.path.expanduser(d.text)))
                k += 2
            elif a == "-c" and k + 1 < len(args):
                if args[k + 1].text.lower().startswith("alias."):
                    raise Block("`git -c alias.…` hides the real subcommand. Run the git "
                                "command directly.")
                if self.role:
                    raise Block("`git -c …` config overrides are outside the %s role." % self.role)
                overrides.append(args[k + 1])
                k += 2
            elif a in ("--git-dir", "--work-tree", "--namespace") and k + 1 < len(args):
                repo = None
                k += 2
            elif a.startswith("-"):
                if a.startswith(("--git-dir=", "--work-tree=")):
                    repo = None
                k += 1
            else:
                break
        if k >= len(args):
            return
        sub, rest = args[k], args[k + 1:]
        if self.role:
            self.check_role_git(sub, rest)
        if sub.dynamic:
            raise Block("the git subcommand `%s` can't be verified. Write it literally." % sub.text)
        name, texts = sub.text, [a.text for a in rest]
        if texts[:1] == ["--help"]:
            return  # `git <subcommand> --help …` opens the manual and exits 0, whatever follows
        if name in PUSHES or (name == "subtree" and texts[:1] == ["push"]):
            for o in overrides:  # `git -c push.default=matching push` goes where the override says
                if o.text.lower().startswith(ROUTES_PUSH) or (o.dynamic and o.text.startswith(EXPANSIONS)):
                    raise Block("`git -c %s` can change where this push goes. Push without it, "
                                "naming the branch: `git push -u origin <branch>`." % o.text)
            self.check_push(rest[1:] if name == "subtree" else rest, repo, plumbing=name != "push" and name != "subtree")
        elif name == "config":
            self.note_config(rest)
        elif name in ("checkout", "switch"):
            self.note_switch(name, rest, repo)
        elif name == "branch":
            self.note_rename(rest, repo)
        elif name == "rebase":
            self.note_rebase(rest, repo)
        elif name == "stash" and texts[:1] == ["branch"] and len(rest) > 1:
            self.move(repo, rest[1])
        elif name == "symbolic-ref" and len(rest) > 1 and texts[0] == "HEAD":
            self.move(repo, Word(texts[1][len("refs/heads/"):] if texts[1].startswith("refs/heads/")
                                 else texts[1], rest[1].dynamic))

    def check_role_git(self, sub, rest):
        allowed = ROLE_RULES[self.role]["git"]
        name = sub.text
        texts = [a.text for a in rest]
        problem = None
        if sub.dynamic or name not in allowed:
            problem = "`git %s` is outside the %s role" % (name, self.role)
        elif name == "branch" and (
                any(t in BRANCH_WRITE_OPTS or t.startswith("--set-upstream-to") for t in texts)
                or (any(not t.startswith("-") for t in texts)
                    and not any(t.split("=", 1)[0] in BRANCH_LIST_OPTS for t in texts))):
            problem = "this `git branch` would create or change a branch, outside the %s role" % self.role
        elif name == "remote" and texts and texts[0] not in ("-v", "--verbose", "show", "get-url"):
            problem = "`git remote %s` is outside the %s role" % (texts[0], self.role)
        elif any(t.startswith("--output") for t in texts):
            problem = "`git %s --output` writes a file, outside the %s role" % (name, self.role)
        if problem:
            raise Block("%s, which reads the repo but never changes it. Allowed git: %s."
                        % (problem, ", ".join(sorted(allowed))))

    # -- which branch is checked out, as this command changes it --------------------------
    def candidates(self, repo):
        """Every branch `repo` may be on when the current step runs; None = can't tell."""
        if not repo or self.lost or self.later:
            return {None}
        key = self.top(repo)
        if key in self.moves:
            new, olds, chain = self.moves[key]
            return {new} if chain == self.chain else {new} | olds
        return {git_out(repo, "symbolic-ref", "--quiet", "--short", "HEAD")}

    def move(self, repo, name, start=None):
        """A step puts `repo` on branch `name` (a Word, a marker, or None) — if it succeeds."""
        if not repo:  # some repo's HEAD moved, and the guard can't tell which
            self.lost = True
            return
        key = self.top(repo)
        # If this step fails the repo stays where it was; if an earlier step of the same chain
        # failed, this one never ran — so every earlier possibility stays possible.
        if key in self.moves:
            olds = self.moves[key][1] | {self.moves[key][0]}
        else:
            olds = self.candidates(repo)
        if isinstance(name, Word):
            name = None if name.dynamic else name.text
        self.moves[key] = (name, olds, self.chain)
        self.starts.pop(key, None)
        if start is not None and not start.dynamic:
            self.starts[key] = start.text

    def note_switch(self, kind, rest, repo):
        if kind == "checkout":
            dashes = next((k for k, a in enumerate(rest) if a.text == "--"), None)
            if dashes is not None:
                if dashes + 1 < len(rest):
                    return  # `git checkout [<tree-ish>] -- <paths>` restores files
                rest = rest[:dashes]  # `git checkout <branch> --` switches
        created, detach, track, positional = None, False, False, []
        k = 0
        while k < len(rest):
            word = rest[k]
            t = word.text
            if t == "--orphan" and k + 1 < len(rest):
                created = rest[k + 1]
                k += 1
            elif t == "--detach":
                detach = True
            elif t.split("=", 1)[0] == "--track":
                track = True
            elif t.startswith("-") and not t.startswith("--") and len(t) > 1:
                for j, flag in enumerate(t[1:], 1):
                    if flag in "bBcC":  # -b <name>, also glued: -bname
                        if j < len(t) - 1:
                            created = Word(t[j + 1:], word.dynamic)
                        elif k + 1 < len(rest):
                            created = rest[k + 1]
                            k += 1
                        break
                    detach = detach or flag == "d"
                    track = track or flag == "t"
            elif not t.startswith("--"):
                positional.append(word)
            k += 1
        if created is not None:
            self.move(repo, created, positional[0] if positional else None)
        elif detach:
            self.move(repo, None)
        elif not positional or (len(positional) > 1 and kind == "checkout"):
            return  # no branch named, or `git checkout <tree-ish> <paths…>`
        else:
            name = positional[0]
            if name.dynamic or name.text == "-":
                self.move(repo, None)
            elif track and "/" in name.text:
                self.move(repo, Word(name.text.split("/", 1)[1]))
            elif kind == "switch":
                self.move(repo, name)
            elif repo and (git_out(repo, "rev-parse", "--verify", "--quiet", "refs/heads/" + name.text)
                           or git_out(repo, "rev-parse", "--verify", "--quiet",
                                      "refs/remotes/origin/" + name.text)):
                self.move(repo, name)
            elif repo and os.path.exists(os.path.join(repo, name.text)):
                return  # `git checkout <path>` restores a file
            else:
                self.move(repo, None)  # a commit, a tag, or something the guard can't see

    def note_config(self, rest):
        """`git config <key> <value>` on a key that routes pushes: a later bare push follows it."""
        texts = [a.text.lower() for a in rest]
        named = [t for t in texts if not t.startswith("-")]
        reads = named[:1] in (["get"], ["list"]) or any(t.startswith(("--get", "--list")) or t == "-l" for t in texts)
        if not reads and any(a.dynamic or a.text.lower().startswith(ROUTES_PUSH) for a in rest) and (
                len(named) > 1 or any(t.startswith(("--add", "--unset", "--replace", "--re", "-e")) for t in texts)):
            self.lost = True

    def note_rename(self, rest, repo):
        """`git branch -m|-M [<old>] <new>` renames; renaming the current branch moves HEAD.
        `git branch -u <upstream>` changes where a bare push goes."""
        if any(a.text == "-u" or a.text.startswith(("--set-upstream-to", "--unset-upstream")) for a in rest):
            self.lost = True
        if not any(a.text == "--move" or (a.text.startswith("-") and not a.text.startswith("--")
                                          and ("m" in a.text or "M" in a.text)) for a in rest):
            return
        names = [a for a in rest if not a.text.startswith("-")]
        if len(names) == 1:
            self.move(repo, names[0])
        elif len(names) > 1:
            current = self.candidates(repo)
            if names[0].dynamic or None in current:
                self.move(repo, None)
            elif names[0].text in current:
                self.move(repo, names[1])

    def note_rebase(self, rest, repo):
        """`git rebase [--onto <base>] <upstream> <branch>` checks <branch> out first."""
        names, k = [], 0
        while k < len(rest):
            t = rest[k].text
            if t in REBASE_VALUE_OPTS:
                k += 1
            elif not t.startswith("-"):
                names.append(rest[k])
            k += 1
        if len(names) > 1 or (names and any(a.text == "--root" for a in rest)):
            self.move(repo, names[-1])

    def protected(self, repo):
        names = set(DEFAULT_PROTECTED)
        names.update(x for x in re.split(r"[,\s]+", os.environ.get("ADLC_PROTECTED_BRANCHES", "")) if x)
        event = os.environ.get("GITHUB_EVENT_PATH")
        if event:  # actions/checkout sets no origin/HEAD; the event names the default branch
            try:
                with open(event) as f:
                    names.add(json.load(f)["repository"]["default_branch"])
            except Exception:
                pass
        for where in {repo, self.home} - {None}:  # after a `cd` it can't follow: the session's repo
            head = git_out(where, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
            if head and "/" in head:
                names.add(head.split("/", 1)[1])
        return names

    def head_targets(self, repo, names, what):
        """The branches a push of HEAD (or a bare push) could update; block if any is unsafe."""
        targets = self.candidates(repo)
        if None in targets:
            raise Block("%s, and the branch it would leave from can't be determined. Name the "
                        "branch: `git push -u origin <branch>`." % what)
        bad = sorted(t for t in targets if t in names)
        if bad and len(targets) > 1:
            raise Block("%s after a step that may have failed, which would leave it on the "
                        "protected branch `%s`. Join the steps with `&&`, or name the branch: "
                        "`git push -u origin <branch>`." % (what, bad[0]))
        if bad:
            raise Block("%s would update the protected branch `%s` (the current branch). Push a "
                        "feature branch — `git push -u origin <branch>` — and open a PR; merging "
                        "is the Principal's Gate 2." % (what, bad[0]))
        return targets

    def check_push(self, args, repo, plumbing=False):
        positional, delete, tags_only = [], False, False
        force = "force-push (`%s`). Never rewrite pushed history — add a new commit instead."
        k = 0
        while k < len(args):
            a = args[k].text
            if a == "--":
                positional.extend(args[k + 1:])
                break
            if a.startswith("--"):
                name = a.split("=", 1)[0]  # git accepts any unambiguous prefix of a long option
                if len(name) > 2 and any(o.startswith(name) for o in FORCE_OPTS):
                    raise Block(force % a)
                if len(name) > 2 and any(o.startswith(name) for o in EVERY_BRANCH_OPTS):
                    raise Block("`git push %s` pushes every branch, protected ones included. "
                                "Push one named feature branch." % a)
                if len(name) > 2 and "--delete".startswith(name):
                    delete = True
                elif name == "--tags":
                    tags_only = True
                elif name == "--push-option" and "=" not in a:
                    k += 1
            elif a.startswith("-") and len(a) > 1:
                for j, flag in enumerate(a[1:], 1):
                    if flag == "o":  # -o <option>: the rest of the word, or the next one, is its value
                        if j == len(a) - 1:
                            k += 1
                        break
                    if flag == "f":
                        raise Block(force % a)
                    if flag == "d":
                        delete = True
            else:
                positional.append(args[k])
            k += 1

        advice = ("Push a feature branch — `git push -u origin <branch>` or `git push -u origin "
                  "HEAD` — and open a PR; merging is the Principal's Gate 2.")
        loose = next((p for p in positional if p.splits and p.text.startswith(EXPANSIONS)), None)
        if loose is not None:  # an unquoted $VAR or $(…) may hold the remote AND a refspec
            raise Block("the push target `%s` can't be verified. Name the remote and the branch "
                        "literally. %s" % (loose.text, advice))
        names = self.protected(repo)
        refspecs = positional[1:]
        if plumbing and not refspecs:  # `git send-pack <remote>` with no refs
            raise Block("`git send-pack` with no refs updates every branch both sides have, "
                        "protected ones included. %s" % advice)
        if not refspecs:
            if tags_only:
                return
            targets = self.head_targets(repo, names, "a push that names no branch")
            routed = git_out(repo, "config", "--get-regexp", r"^(remote\..*\.(push|mirror)|push\.default)$")
            for line in (routed or "").splitlines():
                if not line.lower().startswith("push.default") or line.split()[-1].lower() == "matching":
                    raise Block("a push that names no branch, and this repo's config (`%s`) sends "
                                "such a push to other branches. Name the target: "
                                "`git push -u origin <branch>`." % line)
            key = self.top(repo)
            for current in targets:
                if key in self.moves:  # switched in this command: its upstream is the start point
                    upstream = self.starts.get(key) or (
                        None if current == PR_BRANCH or not repo else git_out(
                            repo, "rev-parse", "--abbrev-ref", "--symbolic-full-name",
                            current + "@{upstream}"))
                else:
                    upstream = git_out(repo, "rev-parse", "--abbrev-ref", "--symbolic-full-name",
                                       "@{upstream}")
                if upstream and "/" in upstream and upstream.split("/", 1)[1] in names:
                    raise Block("this branch tracks the protected branch `%s`, so a bare push "
                                "can land there. Name the target: `git push -u origin <branch>`."
                                % upstream)
            return

        k = 0
        while k < len(refspecs):
            ref = refspecs[k]
            k += 1
            text = ref.text
            if text == "tag":  # `git push origin tag v1.2`
                k += 1
                continue
            if text.startswith("+"):
                raise Block(force % text)
            if text == ":":
                raise Block("the `:` refspec pushes every branch both sides have, protected "
                            "ones included. Push one named feature branch.")
            if ref.dynamic:
                raise Block("the push target `%s` can't be verified. Name the branch literally. %s"
                            % (text, advice))
            if "*" in text:
                raise Block("the wildcard refspec `%s` can match a protected branch. %s" % (text, advice))
            dst = text.split(":", 1)[1] if ":" in text else text
            if not delete and ":" not in text and dst in ("HEAD", "@"):
                self.head_targets(repo, names, "`git push … HEAD`")
                continue
            for prefix in ("refs/heads/", "heads/"):
                if dst.startswith(prefix):
                    dst = dst[len(prefix):]
                    break
            if dst in names:
                raise Block("push to the protected branch `%s`. %s" % (dst, advice))

    # -- gh ----------------------------------------------------------------------------
    def check_gh(self, args, scope):
        positional, k = [], 0
        while k < len(args) and len(positional) < 2:
            a = args[k].text
            if a in ("-R", "--repo", "--hostname") and k + 1 < len(args):
                k += 2
            elif a.startswith("-"):
                k += 1
            else:
                positional.append(args[k])
                k += 1
        if not positional:
            return
        group = positional[0].text
        sub = positional[1].text if len(positional) > 1 else ""
        if self.role:
            groups = ROLE_RULES[self.role]["gh"]
            if positional[0].dynamic or group not in groups or (
                    groups[group] is not None and sub not in groups[group]):
                allowed = ", ".join(
                    "gh %s%s" % (g, "" if s is None else " " + "|".join(sorted(s)))
                    for g, s in sorted(groups.items()))
                raise Block("`gh %s` is outside the %s role. Allowed gh: %s."
                            % ((group + " " + sub).strip(), self.role, allowed))
        # A computed group may be `pr` or `api`; under `pr`, a computed subcommand may be `merge`.
        # (`gh api "repos/$OWNER/…"` has a computed ENDPOINT — check_gh_api reads that.)
        if positional[0].dynamic or (group == "pr" and len(positional) > 1 and positional[1].dynamic):
            raise Block("the gh command `%s` can't be verified. Write it literally."
                        % (group + " " + sub).strip())
        if group == "pr" and sub == "merge":
            raise Block("`gh pr merge`. Merging is the Principal's Gate 2 — no agent merges. "
                        "Post the Proposed Action Card and stop.")
        if group == "alias" and sub in ("set", "import"):  # `gh alias set m 'pr merge'; gh m 5`
            raise Block("`gh alias %s` can hide a blocked command behind a new name. Run gh "
                        "commands under their own names." % sub)
        if group == "pr" and sub == "checkout":
            named = [args[j + 1] for j, a in enumerate(args[:-1]) if a.text in ("-b", "--branch")]
            self.move(self.cwd_of(scope), named[0] if named else PR_BRANCH)
        if group == "api":
            self.check_gh_api(args[args.index(positional[0]) + 1:])

    def check_gh_api(self, args):
        method, implied, from_file, fields, endpoint, unread = None, False, False, [], None, []
        k = 0
        while k < len(args):
            word = args[k]
            a = word.text
            value = args[k + 1] if k + 1 < len(args) else Word()
            if word.dynamic and a.startswith(EXPANSIONS):  # it may expand to `-X DELETE`
                unread.append(word)
                k += 1
                continue
            if a in ("-X", "--method"):
                method = value
                k += 1
            elif a.startswith("--method="):
                method = Word(a.split("=", 1)[1], word.dynamic)
            elif a.startswith("-X") and len(a) > 2:
                method = Word(a[2:], word.dynamic)
            elif a in ("-f", "-F", "--field", "--raw-field"):
                implied = True
                fields.append(value)
                k += 1
            elif a.startswith(("--field=", "--raw-field=")):
                implied = True
                fields.append(Word(a.split("=", 1)[1], word.dynamic))
            elif a[:2] in ("-f", "-F") and len(a) > 2:
                implied = True
                fields.append(Word(a[2:], word.dynamic))
            elif a == "--input" or a.startswith("--input="):
                implied = from_file = True
                k += 0 if "=" in a else 1
            elif a in ("-H", "--header", "-q", "--jq", "-t", "--template", "--hostname",
                       "--cache", "-p", "--preview"):
                k += 1
            elif not a.startswith("-") and endpoint is None:
                endpoint = a
            k += 1
        # One quoted unknown with no other endpoint IS the endpoint (`gh api "$URL"`).
        if (method is not None and method.dynamic) or (
                unread and (len(unread) > 1 or unread[0].splits or endpoint is not None)):
            raise Block("the method of this `gh api` call can't be verified: an argument is "
                        "computed. Agents read through the API only (GET); write the call out.")
        verb = (method.text if method is not None else ("POST" if implied else "GET")).upper()
        if verb == "GET":
            return
        if endpoint == "graphql" and verb == "POST" and not from_file:
            queries = [f for f in fields if f.text.startswith("query=")]
            if queries and not any(
                    q.dynamic or q.text.startswith("query=@") or re.search(r"\bmutation\b", q.text, re.I)
                    for q in queries):
                return  # a literal, read-only GraphQL query
            raise Block("a GraphQL call whose query is a mutation, or can't be read here (a "
                        "variable or a file). Agents read through the API only; inline a "
                        "literal read-only query.")
        raise Block("a non-GET `gh api` call (%s). Agents read through the API only; use "
                    "`gh issue` / `gh pr` subcommands to write. Merging is the Principal's "
                    "Gate 2." % verb)

    # -- curl / wget -------------------------------------------------------------------
    def check_http(self, prog, args):
        texts = [a.text for a in args]
        if not any("api.github.com" in t.lower() or "uploads.github.com" in t.lower()
                   or "GITHUB_API_URL" in t or "GITHUB_GRAPHQL_URL" in t for t in texts):
            if texts[-1:] == [XARGS_INPUT]:  # `echo '-X PUT https://api.github.com/…' | xargs curl`
                self.opaque("`xargs %s`" % prog, moves=False, prefix=prog)
            return
        for k, a in enumerate(args):  # it may expand to `-X POST`; an option's value may not
            if a.dynamic and a.text.startswith(EXPANSIONS) and not (k and texts[k - 1] in HTTP_VALUE_OPTS):
                raise Block("a `%s` call to the GitHub API with a computed argument (`%s`), so "
                            "its method can't be verified. Write the call out." % (prog, a.text))
        method, data, as_query, k = "", False, False, 0
        while k < len(texts):
            t = texts[k]
            nxt = texts[k + 1] if k + 1 < len(texts) else ""
            if t.startswith("--"):
                name, _, value = t.partition("=")
                if name in ("--request", "--method"):
                    method = (value or nxt).upper()
                elif name == "--get":
                    as_query = True
                elif name.startswith(("--data", "--form", "--upload-file", "--json", "--post-data",
                                      "--post-file", "--body-data", "--body-file")):
                    data = True
            elif t.startswith("-") and len(t) > 1 and prog == "curl":
                for j, flag in enumerate(t[1:], 1):
                    if flag == "X":
                        method = (t[j + 1:] or nxt).upper()
                        break
                    if flag == "G":
                        as_query = True
                    elif flag in "dFT":
                        data = True
                        break
                    elif flag in CURL_VALUE_FLAGS:
                        break  # the rest of the word (or the next one) is this option's value
            k += 1
        if method not in ("", "GET", "HEAD") or (data and not (as_query and not method)):
            raise Block("a write to the GitHub API through `%s`. Agents use `gh issue` / `gh pr` "
                        "subcommands to write; merging is the Principal's Gate 2." % prog)


def block(message):
    sys.stderr.buffer.write(("ADLC guard: blocked — %s\n" % message).encode("utf-8"))
    return 2


def main():
    try:
        data = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
    except ValueError:
        return block("unreadable hook input, so nothing could be checked.")
    if not isinstance(data, dict) or data.get("tool_name") != "Bash":
        return 0
    tool_input = data.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str) or not command.strip():
        return 0
    agent = data.get("agent_type")
    agent = agent if isinstance(agent, str) else ""
    cwd = data.get("cwd")
    guard = Guard(agent[len("adlc:"):] if agent.startswith("adlc:") else agent,
                  cwd if isinstance(cwd, str) and cwd else os.getcwd(), command)
    try:
        guard.check_text(command)
    except Block as b:
        return block(str(b))
    except Exception as e:  # a guard bug must not wave a merge or a push through
        if guard.role:
            return block("the guard failed on this command (%s), so the %s role's limits can't "
                         "be checked. Simplify it." % (type(e).__name__, guard.role))
        try:
            guard.raw_scan(command, "a command the guard failed on (%s)" % type(e).__name__)
        except Block as b:
            return block(str(b))
    return 0


if __name__ == "__main__":
    sys.exit(main())
