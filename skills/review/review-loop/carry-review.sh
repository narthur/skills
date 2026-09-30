#!/bin/bash
# post-rewrite: carry a review record onto a rewritten commit when the content is
# provably identical.
#
# A rebase or amend rewrites shas, which invalidates a review record the loop
# legitimately earned.
#
# How much does that actually cost? Of the eight rows in skipped-shas citing a
# rebase, exactly ONE is a pure rename this would have carried; the other seven
# describe real work done during the rebase — conflict resolutions, a re-unioned
# pnpm override, a two-line port — whose patch-ids provably differ. So this fixes
# the clean-rebase case and nothing else, which is the point: a rebase that
# changed anything still owes a review.
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

# An `amend` fired while a rebase is paused (an `edit` or `reword` step) names a
# sha that does not exist yet. `git rebase --abort` then makes it permanently
# unreachable, and nothing would ever remove the record we wrote for it. The final
# `post-rewrite rebase` reports the same old->new mapping once the whole operation
# has actually landed, and never fires at all after an abort — so wait for it.
if [ "${1:-}" = "amend" ]; then
	for d in rebase-merge rebase-apply; do
		# --path-format=absolute: plain --git-path is relative to the CWD. Git runs
		# hooks from the work-tree root, so that resolves correctly here — the flag
		# is a one-word hedge against a caller (a test, a manual run) that cd'd first.
		p=$(git rev-parse --path-format=absolute --git-path "$d" 2>/dev/null) || continue
		[ -e "$p" ] && exit 0
	done
fi

# The patch a commit introduces, independent of its sha and its parents. Empty for
# a merge (no single patch) and for a root commit git cannot diff.
# record-reviewed.sh and record-skipped.sh both trim to the most recent 500 after
# every append. A third writer that skips it just moves the growth somewhere the
# other two can't see.
cap() {
	[ "$(wc -l < "$1" 2>/dev/null || echo 0)" -gt 500 ] || return 0
	tail -n 500 "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

patch_id() {
	git diff-tree -p --no-commit-id "$1" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1
}

# Nothing recorded anywhere means nothing can carry. This runs on every rebase and
# amend in every repo on this machine, so the common case must cost nothing —
# the same reason stop-hook.sh bails on an empty store before spawning anything.
[ -s "$REVIEWED" ] || [ -s "$SKIPPED" ] || exit 0

# Read the whole batch, then ask each store once. Per-line greps cost ~2 forks per
# rewritten commit — 100 of them to establish "nothing to carry" on a 50-commit
# interactive rebase, where 2 will do.
pairs=$(cat)
[ -n "$pairs" ] || exit 0
olds=$(awk '{print $1}' <<<"$pairs" | sort -u)
hits_reviewed=$(grep -Fxf <(printf '%s\n' "$olds") "$REVIEWED" 2>/dev/null || true)
hits_skipped=$(grep -Ff <(printf '%s\n' "$olds") "$SKIPPED" 2>/dev/null | cut -f1 || true)  # batch pre-filter only
[ -n "$hits_reviewed" ] || [ -n "$hits_skipped" ] || exit 0

carried=0
while read -r old new _rest; do
	[ -n "${old:-}" ] && [ -n "${new:-}" ] || continue
	[ "$old" = "$new" ] && continue

	# Only bother when the old sha actually carried a record.
	how=""; skip_line=""
	if grep -qxF "$old" <<<"$hits_reviewed"; then
		how=reviewed
	elif grep -qxF "$old" <<<"$hits_skipped"; then
		# hits_skipped is an unanchored pre-filter, so a hit here only means "worth
		# looking" — the anchored read below is what actually decides. Gating on it
		# is what stops this grepping the whole file once per rewritten commit.
		#
		# That read captures the whole line in one go. Re-reading $SKIPPED later for
		# the reason would be a race: record-skipped.sh replaces the file wholesale
		# (read, temp, mv), so a concurrent worktree can swap it out between two
		# reads and the carried entry lands with a blank reason.
		skip_line=$(grep "^${old}[[:space:]]" "$SKIPPED" 2>/dev/null | head -1)
		[ -n "$skip_line" ] && how=skipped
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

	# Write the audit row FIRST and only change gate state if it lands. The other
	# way round, a missing python or a runlog error would silently mark a sha
	# reviewed with nothing in the record to say why — the same ordering mistake
	# record-skipped.sh already had to correct.
	if [ -f "$RUNLOG" ]; then
		py=$(command -v python3.14 || command -v python3 || true)
		# No python is the same outcome as a failed write: no audit row. Treating it
		# as "fine, carry on" was the half of this the reorder missed — the store got
		# its entry and nothing recorded why, which is what the comment above says
		# can no longer happen.
		if [ -z "$py" ]; then
			echo "review-gate: no python to record the carry of ${old:0:12}; leaving the gate state alone" >&2
			continue
		fi
		"$py" "$RUNLOG" carried --from "$old" --to "$new" --how "$how" \
			--by "patch-id, $mode" >/dev/null 2>&1 || {
			echo "review-gate: could not record the carry of ${old:0:12}; leaving the gate state alone" >&2
			continue
		}
	fi

	if [ "$how" = reviewed ]; then
		printf '%s\n' "$new" >> "$REVIEWED"
		cap "$REVIEWED"
	else
		reason=$(cut -f3- <<<"$skip_line")
		printf '%s\t%s\t%s\n' "$new" "$(date +%F)" "$reason (carried from ${old:0:12} by $mode)" >> "$SKIPPED"
		cap "$SKIPPED"
	fi
	carried=$((carried + 1))
done <<<"$pairs"

[ "$carried" -gt 0 ] && echo "review-gate: carried $carried review record(s) across the $mode" >&2
exit 0
