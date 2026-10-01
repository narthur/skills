#!/bin/bash
# post-rewrite: carry a review record onto a rewritten commit when the content is
# provably identical.
#
# A rebase or amend rewrites shas, which invalidates a review record the loop
# legitimately earned.
#
# How much does that actually cost? Of the eight rows in skipped-shas citing a
# rebase, exactly ONE would have carried: 2026-09-27, a conflict-free rebase onto an
# unrelated commit, whose row says "no content changed between the reviewed tip and
# this one". The other seven record content that differs from the reviewed tip — four
# conflict resolutions, a re-unioned pnpm override, a two-line port, a lockfile-only
# delta — so their patch-ids differ. This fixes the clean-rebase case and nothing
# else, which is the point: a rebase that changed anything still owes a review. (Not
# a rename — no row mentions one. A commit that merely contains a rename carries like
# any other: patch-id covers the file names, so a reproduced rename reproduces its
# id. It is a rewrite that *changes* the names that cannot match.)
#
# The carry is gated on `git patch-id --verbatim`, which compares the patch itself,
# whitespace included.
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
		# Plain --git-path, no --path-format: the path it returns is relative to the
		# CWD, so it resolves from wherever the caller stands — measured from a
		# subdirectory and in a linked worktree. --path-format=absolute added nothing
		# and needed git >= 2.31. Below that the bypass is quieter than it looks:
		# rev-parse echoes an unrecognised flag back and exits 0, so `|| continue`
		# never fires, `$p` holds two lines, `[ -e "$p" ]` is false, and the guard
		# simply never triggers — a mid-rebase amend then carries a record for a sha
		# the rebase may still discard.
		p=$(git rev-parse --git-path "$d" 2>/dev/null) || continue
		[ -e "$p" ] && exit 0
	done
fi

# record-reviewed.sh and record-skipped.sh both trim to the most recent 500 after
# every append. A third writer that skips it just moves the growth somewhere the
# other two can't see.
cap() {
	[ "$(wc -l < "$1" 2>/dev/null || echo 0)" -gt 500 ] || return 0
	tail -n 500 "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# The patch a commit introduces, independent of its sha and its parents. Empty for a
# merge (no single patch) and for a root commit git cannot diff, and the caller
# refuses to carry on an empty id.
#
# --verbatim, NOT --stable (they cannot be combined). --stable strips whitespace
# before hashing, so two commits differing only in indentation share an id — and in
# Python, YAML and shell, indentation is semantics. Measured on git 2.50.1:
# `rm -rf /tmp/junk` and `rm -rf / tmp/junk` collide under --stable and differ under
# --verbatim. (No hash quoted: a patch-id covers the file name and surrounding
# context too, so the value is a property of the fixture, not of the pair of lines.)
#
# For a text diff --verbatim changes exactly that one thing: it still drops the
# `@@ ... @@` line and the `index <old>..<new>` line, so a rebase that only moved the
# hunk's offsets still matches — the whole case this feature exists for. A binary diff
# has neither line; git >= 2.39 hashes the blob oids instead, which is stricter rather
# than looser (a clean rebase preserves the oids, so the carry still works). On git < 2.39 the flag is
# unrecognised: rc 129 and empty stdout, so the id is empty and the caller refuses.
# Fail closed.
patch_id() {
	git diff-tree -p --no-commit-id "$1" 2>/dev/null | git patch-id --verbatim 2>/dev/null | cut -d' ' -f1
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
	# No python, or no runlog.py beside this script, is the same outcome as a failed
	# write: no audit row. Both were once "fine, carry on" — the store got its entry
	# and nothing recorded why, which is what the comment above says can no longer
	# happen. One branch for all three so a fourth cannot be added past it.
	py=$(command -v python3.14 || command -v python3 || true)
	if [ ! -f "$RUNLOG" ] || [ -z "$py" ]; then
		echo "review-gate: cannot record the carry of ${old:0:12} (no runlog); leaving the gate state alone" >&2
		continue
	fi
	"$py" "$RUNLOG" carried --from "$old" --to "$new" --how "$how" \
		--by "patch-id, $mode" >/dev/null 2>&1 || {
		echo "review-gate: could not record the carry of ${old:0:12}; leaving the gate state alone" >&2
		continue
	}

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
