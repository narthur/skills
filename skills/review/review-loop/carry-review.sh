#!/bin/bash
# post-rewrite: carry a review record onto a rewritten commit when the content is
# provably identical.
#
# A rebase or amend rewrites shas, which invalidates a review record the loop
# legitimately earned. Eight rows in skipped-shas exist only to say "review-loop
# reviewed this exact content, then a rebase renamed it" — a false skip that costs
# a real one its meaning, since a store full of bookkeeping entries is one nobody
# reads carefully.
#
# The carry is gated on `git patch-id --stable`, which compares the patch itself.
# That is the right gate rather than a convenient one:
#   - a clean rebase reproduces the same patch, so the record carries
#   - a rebase that resolved a conflict produces a DIFFERENT patch, so it does not,
#     which is correct: that content was never reviewed
#   - a merge commit has no single patch, so it never carries
#
# What it does NOT claim: that reviewed content is still correct against a new
# base. A clean rebase can still break something by interaction. So the carry is
# recorded as its own state (`carried`) in the run record rather than passed off
# as a direct review — reviewed-here and reviewed-then-carried are different
# claims, and a later reader can tell them apart.
#
# Reads post-rewrite's stdin: one "<old-sha> <new-sha>" line per rewritten commit.
# Invoked as: carry-review.sh <amend|rebase>
set -uo pipefail

REVIEWED="$HOME/.claude/review-loop/reviewed-shas"
SKIPPED="$HOME/.claude/review-loop/skipped-shas"
RUNLOG="$(dirname "$0")/runlog.py"
mode="${1:-unknown}"

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# The patch a commit introduces, independent of its sha and its parents. Empty for
# a merge (no single patch) and for a root commit git cannot diff.
patch_id() {
	git diff-tree -p --no-commit-id "$1" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1
}

carried=0
while read -r old new _rest; do
	[ -n "${old:-}" ] && [ -n "${new:-}" ] || continue
	[ "$old" = "$new" ] && continue

	# Only bother when the old sha actually carried a record.
	how=""
	if grep -qxF "$old" "$REVIEWED" 2>/dev/null; then
		how=reviewed
	elif grep -q "^${old}[[:space:]]" "$SKIPPED" 2>/dev/null; then
		how=skipped
	fi
	[ -n "$how" ] || continue

	# Already recorded under the new sha (a second rebase over the same commit)?
	if [ "$how" = reviewed ] && grep -qxF "$new" "$REVIEWED" 2>/dev/null; then continue; fi
	if [ "$how" = skipped ] && grep -q "^${new}[[:space:]]" "$SKIPPED" 2>/dev/null; then continue; fi

	old_pid=$(patch_id "$old")
	new_pid=$(patch_id "$new")
	# No patch id on either side means we cannot prove sameness — don't guess.
	[ -n "$old_pid" ] && [ -n "$new_pid" ] || continue
	[ "$old_pid" = "$new_pid" ] || continue

	if [ "$how" = reviewed ]; then
		printf '%s\n' "$new" >> "$REVIEWED"
	else
		reason=$(grep "^${old}[[:space:]]" "$SKIPPED" | head -1 | cut -f3-)
		printf '%s\t%s\t%s\n' "$new" "$(date +%F)" "$reason (carried from ${old:0:12} by $mode)" >> "$SKIPPED"
	fi

	if [ -f "$RUNLOG" ]; then
		py=$(command -v python3.14 || command -v python3)
		[ -n "$py" ] && "$py" "$RUNLOG" carried --from "$old" --to "$new" --how "$how" \
			--by "patch-id, $mode" >/dev/null 2>&1
	fi
	carried=$((carried + 1))
done

[ "$carried" -gt 0 ] && echo "review-gate: carried $carried review record(s) across the $mode" >&2
exit 0
