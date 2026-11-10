#!/usr/bin/env bash
# Guardrail helper: does a role's comment text carry the markers its duty must produce?
# The table below lists each duty's REQUIRED markers and their form. It is rendered from the
# plugin's contracts/<role>.json by contracts/render.py, because this copy in .adlc/scripts/ is
# frozen and a host repo cannot read the plugin's contracts folder.
# No lane calls this script yet: each lane still reads its marker in its own step
# (adlc-verdict.sh, the intake and the design handoff). Run it by hand, or from a step you add.
#
# Usage:  <comment text> | adlc-outputs.sh <role> <duty>     e.g. adversarial-reviewer review
#   A "last" marker (a verdict): the LAST line that carries the marker must have the form, the
#   way adlc-verdict.sh reads it — an earlier well-formed line does not stand in for it.
#   An "any" marker: one line with the form is enough.
# Exit 0 when every required marker is there in its form; 1 when one is not (each is named on
# stderr); 2 on bad arguments — a role/duty pair with no required marker included (the pairs
# that have one are listed on stderr).
set -euo pipefail
# >>> rendered by contracts/render.py from contracts/*.json: do not edit by hand
# role, duty, marker, which line (any|last), form, the extended regex of the form; tab-separated
table() { cat <<'ADLC_OUTPUTS'
product-analyst	triage	ADLC-TRIAGE	any	ADLC-TRIAGE: FAST|FULL	ADLC-TRIAGE:[[:space:]]*(FAST|FULL)
architect	design	ADLC-BREAKDOWN	any	ADLC-BREAKDOWN: <ADR path>	ADLC-BREAKDOWN:[[:space:]`*_]*[^[:space:]`*_]
architect	review	ADLC-ARCH	last	ADLC-ARCH: PASS|CHANGES	(^|[^[:alnum:]_-])ADLC-ARCH:[*`_[:space:]]*(PASS|CHANGES)([^[:alnum:]_].*)?$
adversarial-reviewer	review	ADLC-ADV	last	ADLC-ADV: PASS|CHANGES	(^|[^[:alnum:]_-])ADLC-ADV:[*`_[:space:]]*(PASS|CHANGES)([^[:alnum:]_].*)?$
ADLC_OUTPUTS
}
# <<< rendered
role="${1:-}"; duty="${2:-}"
pairs() { table | cut -f1,2 | sort -u | tr '\t' ' ' | sed 's/^/  /'; }
if [ $# -ne 2 ] || [ -z "$role" ] || [ -z "$duty" ]; then
  { echo "usage: <comment text> | adlc-outputs.sh <role> <duty>, one of:"; pairs; } >&2; exit 2
fi
known=""
while IFS=$'\t' read -r r d _rest; do
  [ "$r" = "$role" ] && [ "$d" = "$duty" ] && known=1
done < <(table)
if [ -z "$known" ]; then
  { echo "adlc-outputs: no required marker is defined for '${role} ${duty}'. Known:"; pairs; } >&2; exit 2
fi
text="$(cat)"
missing=0
while IFS=$'\t' read -r r d marker which form ere; do
  [ "$r" = "$role" ] && [ "$d" = "$duty" ] || continue
  case "$which" in
    any)  line="$text"; lacks="no line with \`${form}\`" ;;
    last) line="$(grep -E -- "(^|[^[:alnum:]_-])${marker}:" <<<"$text" | tail -1 || true)"
          if [ -n "$line" ]; then lacks="the last \`${marker}:\` line is not \`${form}\`"; else lacks="no \`${form}\` line"; fi ;;
    *)    echo "adlc-outputs: the table row for ${marker} is malformed" >&2; exit 1 ;;
  esac
  rc=0; grep -qE -- "$ere" <<<"$line" || rc=$?
  case "$rc" in
    0) ;;
    1) missing=$((missing + 1)); echo "adlc-outputs: ${role} ${duty}: ${lacks}" >&2 ;;
    *) echo "adlc-outputs: could not check ${marker} (grep exit ${rc})" >&2; exit 1 ;;
  esac
done < <(table)
[ "$missing" -eq 0 ]
