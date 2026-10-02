#!/bin/bash
# The Dismissed list suppresses a class of finding on every future run, so it is
# the busiest way "code like this already exists here" can quietly cut review.
# These check that the ban reaches it without blocking legitimate entries.
#   ./learn.test.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 1
PY=$(command -v python3.14 || command -v python3)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/learn-test.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0
ok() { echo "  ok  $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }

F="$TMP/learnings.md"
fresh() { printf '# L\n\n## Dismissed\n\n## Accepted patterns\n' > "$F"; }

"$PY" learn.py --selftest >/dev/null 2>&1 && ok "learn.py's own selftest passes" || bad "learn.py's own selftest passes"

fresh
out=$("$PY" learn.py add "$F" "consistent with existing code here" --section dismissed 2>&1)
if [ $? -ne 0 ] && grep -qi precedent <<<"$out"; then ok "a precedent dismissal is refused"; else bad "a precedent dismissal is refused"; fi
grep -q "consistent with existing" "$F" \
	&& bad "a refused dismissal must not be written" || ok "a refused dismissal is not written"

out=$("$PY" learn.py add "$F" "this is how the rest of the codebase does it" --section dismissed 2>&1)
[ $? -ne 0 ] && ok "a paraphrased precedent dismissal is refused" || bad "a paraphrased precedent dismissal is refused"

fresh
"$PY" learn.py add "$F" "the CLI entrypoint logs to stdout on purpose; it is the output" --section dismissed >/dev/null 2>&1 \
	&& ok "a legitimate dismissal is written" || bad "a legitimate dismissal is written"
grep -q "on purpose" "$F" && ok "its text reaches the file" || bad "its text reaches the file"

# Accepted entries argue FOR flagging something, so precedent language there is
# not the failure this ban exists to stop.
fresh
"$PY" learn.py add "$F" "flag any new call that mirrors the existing retry helper without its backoff" --section accepted >/dev/null 2>&1 \
	&& ok "the ban does not apply to accepted patterns" || bad "the ban does not apply to accepted patterns"

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit "$fails"
