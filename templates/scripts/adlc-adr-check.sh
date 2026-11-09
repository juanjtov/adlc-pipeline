#!/usr/bin/env bash
# Guardrail: hold an ADR to its own words. An ADR's `## Scope` must be the scope the diff-scope
# check enforces, and every row of its `## Guarantees` table must name a test that exists or say
# that nothing enforces the claim, and why. Without it a Decision can promise more than the code
# or the tests deliver, and nothing fails when the promise rots. Run by the Builder before it
# opens a PR, by the Architect in its conformance review and by QA with the battery (their role
# prompts say so); no workflow calls it.
#
# Usage:  adlc-adr-check.sh [adr-dir]        (default docs/adr; run from the repo root: the
#         paths in a Guarantees row and .adlc/scope/<issue>.txt are read relative to it)
#
# WHICH ADRs: every *.md in the directory except template.md that has a `## Scope` OR a
#   `## Guarantees` heading. An ADR with neither is skipped and listed on stdout. That is how
#   ADRs written before the template had the two sections keep passing, with no state file and
#   no cut-off number to maintain. The weakness: an ADR written today with BOTH sections left
#   out is skipped too. The script cannot tell it from an old one; the conformance review reads
#   the skipped list.
#
# A checked ADR FAILS (one line per problem on stderr, every problem, exit 1) when:
#   - `## Scope` or `## Guarantees` is missing;
#   - Scope has no fenced block (``` … ```). Its lines, one path prefix each, blank lines and
#     `#` comments ignored, are the scope; an empty block is a decision that touches no file;
#   - Guarantees has no table row, or a row's last cell is neither
#       `path::node`             path is an existing file, and node (the text after the last
#                                `::`, a trailing `[param]` dropped) is in it as a whole word, nor
#       `unenforced — <reason>`  with a reason (any dash, a colon or a space before it; an
#                                unfilled `<…>` is no reason);
#   - the ADR names its issue (`**Issue:** #N`, above the first `## `) and `.adlc/scope/N.txt`
#     exists, and the two differ: a Scope line that is not in the scope file, or a scope-file
#     line that is in no Scope section of the ADRs naming that issue. Lines of the scope file
#     under `docs/` are left out of the second half: the design lane starts the file with the
#     `docs/` files it commits (the ADR among them), and it stages nothing else, so that rule
#     cannot fail a PR for what the lane wrote. The cost: a `docs/` prefix the Builder adds to
#     the scope file on its own is not caught here.
#   No issue named, or no scope file yet (the state at design time): Scope is not compared, and
#   stdout says so.
# The node check is a word search, not a test collector: it shows the name is in the file, not
# that a test runner would collect it or that the test asserts the claim.
#
# Exit 0 = nothing to report (also when the directory does not exist: a note, no failure),
#      1 = at least one problem, or an ADR or scope file that could not be read,
#      2 = bad arguments (more than one, an option, a path that is not a directory).
set -uo pipefail
usage() { echo "usage: adlc-adr-check.sh [adr-dir]   (default docs/adr)" >&2; exit 2; }
[ "$#" -le 1 ] || usage
dir="${1:-docs/adr}"
case "$dir" in -*) usage ;; esac
[ "$dir" = / ] || dir="${dir%/}"
if [ ! -e "$dir" ]; then echo "adr-check: no ADR directory (${dir}) — nothing to check"; exit 0; fi
[ -d "$dir" ] || { echo "adlc-adr-check: ${dir} is not a directory" >&2; exit 2; }

probs=0; checked=0; skipped=""; issues=""
problem() { echo "$1" >&2; probs=$((probs + 1)); }
tmp="$(mktemp -d)" || { echo "adlc-adr-check: could not create a scratch directory" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
US=$(printf '\037')   # field separator of the parse below: not whitespace, so an empty field stays a field

# One pass over an ADR. Prints, US-separated:
#   H scope | H guar     the heading is there        I <n>          the issue the header names
#   F                    Scope has a fenced block    S <prefix>     one line of that block
#   R <last cell> <the cells before it>              one Guarantees row (header and |---| rows dropped)
# Headings and rows inside a fenced block are text, not structure.
parse() {
  awk -v US="$US" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function rows(   i) {
      for (i = 1; i <= nr; i++) if (!sep[i] && !sep[i + 1]) print "R" US pin[i] US claim[i]
      for (i = 1; i <= nr + 1; i++) delete sep[i]
      nr = 0
    }
    { sub(/\r$/, "") }
    /^[ \t]*(```|~~~)/ {
      fence = !fence
      if (fence && sec == "scope" && !block) { block = 1; inblock = 1; print "F" } else if (!fence) inblock = 0
      next
    }
    inblock { l = trim($0); if (l != "" && l !~ /^#/) print "S" US l; next }
    fence { next }
    /^##?[ \t]/ {
      rows(); sec = ""; h = tolower(trim($0))
      if (h ~ /^## /) body = 1
      if (h == "## scope") { sec = "scope"; print "H" US "scope" }
      if (h == "## guarantees") { sec = "guar"; print "H" US "guar" }
      next
    }
    !body && !issue && match($0, /\*\*Issue:\*\*[ \t]*#?[0-9]+/) {
      n = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", n); print "I" US n; issue = 1
    }
    sec == "guar" && /^[ \t]*\|/ {
      row = trim($0); gsub(/\t/, " ", row); sub(/^\|/, "", row); sub(/\|$/, "", row)
      nr++; sep[nr] = (row ~ /^[-: |]+$/ && row ~ /-/)
      cut = 0; for (i = 1; i <= length(row); i++) if (substr(row, i, 1) == "|") cut = i
      p = substr(row, cut + 1); gsub(/`/, "", p); pin[nr] = trim(p)
      claim[nr] = (cut > 1) ? trim(substr(row, 1, cut - 1)) : ""
    }
    END { rows() }' "$1"
}

lines_of() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' "$1"; }   # a scope file, as adlc-diff-scope.sh reads it

guarantee() { # <adr> <last cell> <claim>
  local adr="$1" pin="$2" row="${3:-(no claim)}" r path node
  case "$pin" in
    [Uu]nenforced|[Uu]nenforced[!A-Za-z0-9_/.]*)
      r="${pin#?nenforced}"
      while :; do
        case "$r" in
          ' '*) r="${r# }" ;; '-'*) r="${r#-}" ;; ':'*) r="${r#:}" ;; '—'*) r="${r#—}" ;; '–'*) r="${r#–}" ;;
          *) break ;;
        esac
      done
      case "$r" in ''|'<'*'>') problem "${adr}: Guarantees row '${row}': unenforced, with no reason" ;; esac ;;
    *::*)
      path="${pin%%::*}"; node="${pin##*::}"; node="${node%%\[*}"
      path="${path%"${path##*[! ]}"}"; node="${node#"${node%%[! ]*}"}"; node="${node%"${node##*[! ]}"}"
      if [ -z "$path" ] || [ -z "$node" ]; then
        problem "${adr}: Guarantees row '${row}': '${pin}' is not a path::node"
      elif [ ! -f "$path" ]; then
        problem "${adr}: Guarantees row '${row}': ${path} does not exist"
      elif ! grep -qwF -- "$node" "$path" 2>/dev/null; then
        problem "${adr}: Guarantees row '${row}': '${node}' is not in ${path}"
      fi ;;
    *) problem "${adr}: Guarantees row '${row}': '${pin}' is neither a path::node nor 'unenforced — <reason>'" ;;
  esac
}

for f in "$dir"/*.md; do
  [ -f "$f" ] || continue
  name="${f##*/}"
  [ "$name" = template.md ] && continue
  parsed="$(parse "$f")" || { problem "${f}: could not be read"; continue; }
  has_scope=""; has_guar=""; has_block=""; issue=""; nrows=0
  : > "$tmp/scope"
  while IFS="$US" read -r tag a b; do
    case "$tag" in
      H) if [ "$a" = scope ]; then has_scope=1; else has_guar=1; fi ;;
      I) issue="$a" ;;
      F) has_block=1 ;;
      S) printf '%s\n' "$a" >> "$tmp/scope" ;;
    esac
  done <<<"$parsed"
  if [ -z "$has_scope" ] && [ -z "$has_guar" ]; then skipped="${skipped} ${name}"; continue; fi
  checked=$((checked + 1))

  if [ -z "$has_guar" ]; then
    problem "${f}: no '## Guarantees' section"
  else
    while IFS="$US" read -r tag a b; do
      [ "$tag" = R ] || continue
      nrows=$((nrows + 1)); guarantee "$f" "$a" "$b"
    done <<<"$parsed"
    [ "$nrows" -gt 0 ] || problem "${f}: '## Guarantees' has no table row (a decision that promises nothing testable says so in one 'unenforced — <reason>' row)"
  fi

  if [ -z "$has_scope" ]; then
    problem "${f}: no '## Scope' section"
  elif [ -z "$has_block" ]; then
    problem "${f}: '## Scope' has no fenced block of path prefixes"
  elif [ -z "$issue" ]; then
    echo "adr-check: ${f} names no issue (**Issue:** #N) — its Scope is not compared with a scope file"
  elif [ ! -f ".adlc/scope/${issue}.txt" ]; then
    echo "adr-check: ${f}: no .adlc/scope/${issue}.txt yet — its Scope is not compared"
  elif ! lines_of ".adlc/scope/${issue}.txt" > "$tmp/file" 2>/dev/null; then
    problem "${f}: .adlc/scope/${issue}.txt could not be read"
  else
    while IFS= read -r line; do
      grep -qxF -- "$line" "$tmp/file" || problem "${f}: Scope line '${line}' is not in .adlc/scope/${issue}.txt"
    done < "$tmp/scope"
    cat "$tmp/scope" >> "$tmp/union.${issue}"
    printf ' %s' "$name" >> "$tmp/adrs.${issue}"
    case " $issues " in *" $issue "*) ;; *) issues="${issues} ${issue}" ;; esac
  fi
done

# The other half of the comparison, once per issue: a line of the scope file that no ADR naming
# the issue lists. Against the union, so two ADRs of one issue do not fail each other.
for issue in $issues; do
  lines_of ".adlc/scope/${issue}.txt" > "$tmp/file" 2>/dev/null || { problem ".adlc/scope/${issue}.txt could not be read"; continue; }
  while IFS= read -r line; do
    case "$line" in docs/*) continue ;; esac
    grep -qxF -- "$line" "$tmp/union.${issue}" \
      || problem ".adlc/scope/${issue}.txt: '${line}' is in no Scope section of the ADR(s) naming issue ${issue} (in ${dir}:$(cat "$tmp/adrs.${issue}"))"
  done < "$tmp/file"
done

[ -z "$skipped" ] || echo "adr-check: skipped, neither '## Scope' nor '## Guarantees' (written before the template had them?):${skipped}"
if [ "$probs" -eq 0 ]; then echo "adr-check: OK — ${checked} ADR(s) checked in ${dir}"; exit 0; fi
echo "adr-check: ${probs} problem(s) in ${dir}"
exit 1
