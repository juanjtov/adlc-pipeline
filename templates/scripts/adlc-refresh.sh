#!/usr/bin/env bash
# ADLC tooling refresh: compare the plugin's files with the copies installed in a host repo, one
# by one, and copy only those the host has not taken over. The wizard (/adlc-init) runs it FROM
# THE PLUGIN, ${CLAUDE_PLUGIN_ROOT}/templates/scripts/adlc-refresh.sh: it reads the templates
# beside itself, so it is the one script here that is not copied into .adlc/scripts/.
#
# Why a script: the refresh used to copy templates/scripts/*.sh over the host's copies with no
# comparison, so a host that had changed one (its own metrics, a local fix) lost the change, and
# every refresh meant a diff of each file by hand.
#
# Usage:  adlc-refresh.sh [--apply] <host-root>
#           The files copied as they are: every templates/scripts/*.sh but this one
#           → .adlc/scripts/ (executable), and templates/LICENSE → .adlc/LICENSE.
#         adlc-refresh.sh [--apply] <host-root> <filled-file> <target>
#           One file the wizard fills before it copies (a workflow, an agent copy, the pre-commit
#           hook; one with nothing to fill is its own filled file). <filled-file> is the filled
#           result, anywhere on disk; <target> is where it goes, relative to the host root, and
#           must be one of: .github/workflows/adlc-<name>.yml ·
#           .github/ISSUE_TEMPLATE/requirement.yml · .claude/agents/adlc-<role>.md ·
#           .git/hooks/pre-commit. A filled file that still holds a {{PLACEHOLDER}} is refused.
#
# Prints one line per file, `<status>  <target>`:
#   same                          the installed copy is the plugin's, byte for byte
#   new                           the host has no such file yet
#   changed                       they differ; a unified diff follows (installed → plugin)
#   host-owned (skipped)          one of the installed file's first five lines contains
#                                 `adlc: host-owned` (write it in a comment, e.g.
#                                 `# adlc: host-owned`): the host keeps this file, and no refresh
#                                 overwrites it
#   not a plain file (skipped)    the target, or a folder above it inside the host, is a link, or
#                                 the target is a directory: nothing is written through it
# Without --apply nothing is written. With --apply the `new` and `changed` files are copied and
# nothing else is touched: no other file is written, and nothing is ever deleted (a target's
# missing folder is created, except under .git). A script, the hook, and any file whose source
# or installed copy is executable end up executable. The output
# ends with the files it skipped; bringing a host-owned one up to date with the plugin's is the
# host's to do.
#
# Exit: 0 the comparison ran (and with --apply every new or changed file was copied); skipped
#         files do not change it, the list is the report
#       1 a file could not be read, compared or written (what was copied before it stays copied)
#       2 bad arguments
set -uo pipefail
unset CDPATH   # with it exported, the `cd` that finds the templates below prints where it went
MARK='adlc: host-owned'
die() { echo "adlc-refresh: $2" >&2; exit "$1"; }
usage() { die 2 "usage: adlc-refresh.sh [--apply] <host-root> [<filled-file> <target>]"; }

apply=""
if [ "${1:-}" = "--apply" ]; then apply=1; shift; fi
case "${1:-}" in ''|-*) usage ;; esac
[ $# -eq 1 ] || [ $# -eq 3 ] || usage
root="${1%/}"; [ -n "$root" ] || root=/
[ -d "$root" ] || die 2 "the host root '$1' is not a directory"

tpl="$(cd "$(dirname "$0")/.." && pwd)" || die 1 "cannot find the templates beside $0"

host_owned() { awk -v m="$MARK" 'NR <= 5 && index($0, m) { f = 1 } NR > 5 { exit } END { exit !f }' "$1"; }
linked() { # <target>: a link at the path or at a folder above it, inside the host root
  local p="$1"
  while [ "$p" != . ] && [ "$p" != / ] && [ -n "$p" ]; do
    [ -L "$root/$p" ] && return 0
    p="$(dirname "$p")"
  done
  return 1
}

copied=0; unchanged=0; skipped=""
skip() { skipped="${skipped}${skipped:+
}$1"; }

one() { # <plugin file> <target, relative to the host root> <x: must be executable | ->
  local src="$1" rel="$2" dst="$root/$2" want_x="" rc
  [ -f "$src" ] && [ -r "$src" ] || die 1 "cannot read $src"
  if [ "$3" = x ] || [ -x "$src" ] || { [ -f "$dst" ] && [ -x "$dst" ]; }; then want_x=1; fi
  if linked "$rel" || { [ -e "$dst" ] && [ ! -f "$dst" ]; }; then
    printf '%-28s %s\n' "not a plain file (skipped)" "$rel"
    skip "$rel — not a plain file (a link, a directory, or under a linked folder)"
    return 0
  elif [ ! -e "$dst" ]; then
    printf '%-28s %s\n' "new" "$rel"
  elif host_owned "$dst"; then
    printf '%-28s %s\n' "host-owned (skipped)" "$rel"
    skip "$rel — host-owned"
    return 0
  elif cmp -s "$src" "$dst"; then
    printf '%-28s %s\n' "same" "$rel"
    unchanged=$((unchanged + 1))
    return 0
  else
    printf '%-28s %s\n' "changed" "$rel"
    diff -u -L "$rel (installed)" -L "$rel (plugin)" "$dst" "$src"; rc=$?
    [ "$rc" -eq 1 ] || die 1 "could not compare $dst with $src"
  fi
  if [ -n "$apply" ]; then
    case "$rel" in
      .git/*) [ -d "$(dirname "$dst")" ] || die 1 "no $(dirname "$rel")/ in the host root (not a git checkout, or a worktree, which keeps its hooks elsewhere)" ;;
      *)      mkdir -p "$(dirname "$dst")" || die 1 "could not create $(dirname "$dst")" ;;
    esac
    cp "$src" "$dst" || die 1 "could not write $dst"
    if [ -n "$want_x" ]; then chmod +x "$dst" || die 1 "could not make $dst executable"; fi
  fi
  copied=$((copied + 1))
}

if [ $# -eq 1 ]; then
  [ -d "$tpl/scripts" ] && [ -d "$tpl/github" ] && [ -f "$tpl/LICENSE" ] \
    || die 1 "$tpl does not hold the plugin's templates — run the plugin's own copy of this script"
  for f in "$tpl"/scripts/*.sh; do
    [ -f "$f" ] || continue
    [ "${f##*/}" = adlc-refresh.sh ] && continue
    one "$f" ".adlc/scripts/${f##*/}" x
  done
  one "$tpl/LICENSE" ".adlc/LICENSE" -
else
  filled="$2"; target="${3#./}"; x=-
  [ -f "$filled" ] && [ -r "$filled" ] || die 2 "the filled file '$filled' is not a readable file"
  dir="${target%/*}"; base="${target##*/}"
  case "$base" in ''|.*|*[!A-Za-z0-9._-]*) die 2 "'$3' is not a target this script writes" ;; esac
  case "$dir/$base" in
    .github/workflows/adlc-?*.yml|.github/ISSUE_TEMPLATE/requirement.yml|.claude/agents/adlc-?*.md) ;;
    .git/hooks/pre-commit) x=x ;;
    *) die 2 "'$3' is not a target this script writes (a workflow, the issue template, an agent copy or the pre-commit hook)" ;;
  esac
  case "$dir" in .github/workflows|.github/ISSUE_TEMPLATE|.claude/agents|.git/hooks) ;; *) die 2 "'$3' is not a target this script writes" ;; esac
  if grep -qE '\{\{[A-Z_]+\}\}' "$filled"; then
    die 2 "the filled file still holds a {{PLACEHOLDER}} ($(grep -oE '\{\{[A-Z_]+\}\}' "$filled" | sort -u | tr '\n' ' ')) — fill it first"
  fi
  one "$filled" "$target" "$x"
fi

nskip=0; [ -z "$skipped" ] || nskip=$(printf '%s\n' "$skipped" | grep -c .)
if [ -n "$apply" ]; then
  echo "copied: ${copied} · unchanged: ${unchanged} · skipped: ${nskip}"
else
  echo "to copy: ${copied} · unchanged: ${unchanged} · skipped: ${nskip} — nothing written (run again with --apply to copy)"
fi
if [ -n "$skipped" ]; then
  echo "skipped (left exactly as they are):"
  printf '%s\n' "$skipped" | sed 's/^/  /'
fi
exit 0
