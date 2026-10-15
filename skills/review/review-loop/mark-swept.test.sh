#!/bin/bash
# mark-swept.py writes the sweep marker; `looper context` reads it. The format had no
# producer under test at all, only prose telling an LLM what to type, so nothing would have
# noticed the two drifting apart, and the drift is silent in one direction: the trigger
# reverts to a bare count. The reader's own cases live in looper (internal/gather).
#   ./mark-swept.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fails=0
ok() { echo "  ok  $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/mark-swept.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
g() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=t@t -c user.name=t "$@"; }
r="$TMP/r"
g init -q "$r" && : > "$r/seed" && g -C "$r" add -A && g -C "$r" commit -qm seed
lf="$r/.git/info/review-loop-learnings.md"
mkdir -p "$r/.git/info"
{ printf '# Review-loop learnings\n\n'; for i in $(seq 1 38); do printf -- '- entry %s\n' "$i"; done; } > "$lf"
python3 "$HERE/mark-swept.py" "$lf" >/dev/null || bad "mark-swept.py ran"
grep -qx '<!-- swept: 38 -->' "$lf" && ok "mark-swept.py stamps the surviving count" || bad "mark-swept.py stamps the surviving count"

if command -v looper >/dev/null 2>&1; then
	# No origin: the base is unresolved, which does not touch the learnings fields.
	swept=$(cd "$r" && HOME="$TMP" looper context 2>/dev/null \
		| python3 -c 'import json,sys; print(json.load(sys.stdin)["learnings_swept_entries"])')
	[ "$swept" = "38" ] \
		&& ok "what mark-swept.py writes is what looper context reads" \
		|| bad "what mark-swept.py writes is what looper context reads (got $swept)"
else
	echo "  skip  looper not on PATH — the reader check did not run"
fi

echo
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
