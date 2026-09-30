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
# It also writes a complete plan+finish row to the shared run record
# (~/.claude/review-loop/runs.jsonl), so a skip appears in review-stats.py
# alongside real runs instead of living only in this script's own store. That
# write happens FIRST, because it is the only step that can refuse the reason and
# a refusal afterwards could not restore a previous record it had already
# overwritten. record-reviewed.sh has no equivalent write, so the two are no
# longer symmetric: this one does strictly more.
#
#   record-skipped.sh "<reason>" [<sha, default HEAD>]
set -euo pipefail
# Collapse the delimiters before anything else looks at the reason: the store is one
# line per sha, tab-separated, and capped by line count, so a tab or newline in here
# would forge extra well-formed lines and evict real records.
reason=$(printf '%s' "${1:-}" | tr '\n\t' '  ')
# Blank after that collapse counts as missing — a reason of pure whitespace is the
# silent rubber-stamp this check exists to refuse.
case "$reason" in
	*[![:space:]]*) ;;
	*) echo "record-skipped: a reason is required — e.g. record-skipped.sh 'comment-only, actionlint green'" >&2; exit 1 ;;
esac
# A flag is a mistake, not a reason: `record-skipped.sh --help` would otherwise record
# the string "--help" against HEAD and exit 0. Only a whitespace-free dash token is a
# flag; prose that opens with a dash ("- doc-only") is a legitimate reason.
case "$reason" in
	*[[:space:]]*) ;;
	-*) echo "record-skipped: '$reason' is a flag, not a reason — usage: record-skipped.sh \"<reason>\" [<sha>]" >&2; exit 2 ;;
esac
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
# Drop this sha's line from the store, so a re-record replaces rather than
# duplicates. No longer used for rollback: the runlog write happens before
# skipped-shas is touched, so a refused reason has nothing here to undo.
drop_sha() {
	[ -f "$STORE" ] || return 0
	# `cmd || rc=$?` is an || compound, so set -e does not fire on grep's status.
	# A bare `grep ... > file` here would abort the whole script the moment grep
	# exits 1 — which is the ordinary case where every line matched and the result
	# is legitimately empty, i.e. re-recording the only sha in the store.
	local rc=0
	grep -v "^$1	" "$STORE" > "$STORE.tmp" 2>/dev/null || rc=$?
	if [ "$rc" -le 1 ]; then
		mv "$STORE.tmp" "$STORE"
	else
		rm -f "$STORE.tmp"
		return 1
	fi
}
mkdir -p "$(dirname "$STORE")"
sha=$(resolve_sha "${2:-HEAD}")
# One line per sha (tab-separated: sha, date, reason); refresh if re-recorded.
# Write the run-record row FIRST: it is the only step that can refuse (a reason
# citing precedent), and refusing after the skipped-shas line is rewritten would
# destroy a previous, perfectly good record for this sha without being able to
# put it back. Nothing here touches skipped-shas until the reason has passed.
RUNLOG="$(dirname "$0")/runlog.py"
if [ -f "$RUNLOG" ]; then
	py=$(command -v python3.14 || command -v python3)
	if [ -n "$py" ] && ! "$py" "$RUNLOG" skipped --reason "$reason" >/dev/null; then
		echo "record-skipped: reason refused, nothing recorded" >&2
		exit 1
	fi
fi

drop_sha "$sha"
printf '%s\t%s\t%s\n' "$sha" "$(date +%F)" "$reason" >> "$STORE"
# Bound growth — keep the most recent 500.
if [ "$(wc -l < "$STORE" 2>/dev/null || echo 0)" -gt 500 ]; then
	tail -n 500 "$STORE" > "$STORE.tmp" && mv "$STORE.tmp" "$STORE"
fi
echo "review-gate: recorded SKIPPED sha ${sha:0:12} — $reason"
