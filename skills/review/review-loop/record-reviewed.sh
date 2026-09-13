#!/bin/bash
# Record a commit sha as reviewed, so the pre-push review-gate recognizes it.
# Called by review-loop on a clean loop exit (Step 14), before the auto-push decision.
#   record-reviewed.sh [<sha, default HEAD>]
set -euo pipefail
# Resolve a commit-ish to a bare 40-hex sha, or fail loudly. Without this,
# `git rev-parse --help` exits 0 and prints a man page to stdout, which then
# gets appended to the store as if it were a sha — and since the store is
# capped by `tail -n 500`, that one mistake evicts every real sha behind it.
# Lost the whole store to it on 2026-09-12.
resolve_sha() {
	case "$1" in
		-*) echo "${0##*/}: '$1' is a flag, not a commit — this script takes a commit-ish, nothing else" >&2; exit 2 ;;
	esac
	local out
	out=$(git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null) || {
		echo "${0##*/}: '$1' does not name a commit here" >&2; exit 2; }
	case "$out" in
		*[!0-9a-f]* | "") echo "${0##*/}: refusing to record '$out' — not a sha" >&2; exit 2 ;;
	esac
	[ ${#out} -eq 40 ] || { echo "${0##*/}: refusing to record a ${#out}-character sha" >&2; exit 2; }
	printf '%s' "$out"
}

STORE="$HOME/.claude/review-loop/reviewed-shas"
mkdir -p "$(dirname "$STORE")"
sha=$(resolve_sha "${1:-HEAD}")
grep -qxF "$sha" "$STORE" 2>/dev/null || printf '%s\n' "$sha" >> "$STORE"
# Bound growth — keep the most recent 500.
if [ "$(wc -l < "$STORE" 2>/dev/null || echo 0)" -gt 500 ]; then
	tail -n 500 "$STORE" > "$STORE.tmp" && mv "$STORE.tmp" "$STORE"
fi
echo "review-gate: recorded reviewed sha ${sha:0:12}"
