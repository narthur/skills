#!/bin/bash
# Record a commit sha as DELIBERATELY SKIPPED — judged beneath the review loop
# (a tiny comment/doc/config follow-up) and consciously NOT run through it. Clears
# the pre-push review-gate while keeping an honest, auditable record of that call.
#
# This is the honest counterpart to record-reviewed.sh, NOT a substitute for it:
# it writes a DIFFERENT state (skipped, with your reason) on purpose. If a real
# review pass actually ran — even the Step 3b fast path — use record-reviewed.sh.
# Hand-calling record-reviewed.sh on a change no loop looked at records a review
# that never happened; that is the exact dishonesty this tool exists to make
# unnecessary. A reason is required so the record can't be a silent rubber-stamp.
#
#   record-skipped.sh "<reason>" [<sha, default HEAD>]
set -euo pipefail
reason="${1:-}"
if [ -z "$reason" ]; then
	echo "record-skipped: a reason is required — e.g. record-skipped.sh 'comment-only, actionlint green'" >&2
	exit 1
fi
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

STORE="$HOME/.claude/review-loop/skipped-shas"
mkdir -p "$(dirname "$STORE")"
sha=$(resolve_sha "${2:-HEAD}")
# One line per sha (tab-separated: sha, date, reason); refresh if re-recorded.
if [ -f "$STORE" ]; then
	grep -v "^$sha	" "$STORE" > "$STORE.tmp" 2>/dev/null || true
	mv "$STORE.tmp" "$STORE"
fi
printf '%s\t%s\t%s\n' "$sha" "$(date +%F)" "$reason" >> "$STORE"
# Bound growth — keep the most recent 500.
if [ "$(wc -l < "$STORE" 2>/dev/null || echo 0)" -gt 500 ]; then
	tail -n 500 "$STORE" > "$STORE.tmp" && mv "$STORE.tmp" "$STORE"
fi
echo "review-gate: recorded SKIPPED sha ${sha:0:12} — $reason"
