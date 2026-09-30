#!/bin/bash
# Self-heal: ensure a husky repo has the untracked delegators that hand control to
# the global review hooks. Husky's local core.hooksPath shadows the global hooks,
# so without these neither fires here.
#
#   pre-push     -> ~/.git-hooks/review-gate.sh          (blocks unreviewed pushes)
#   post-rewrite -> the skill's own carry-review.sh       (carries a record across a rebase)
#
# carry-review.sh is referenced at its versioned home in the skill rather than
# copied into ~/.git-hooks, which is untracked in either dotfiles repo.
#
# No-op unless this is a husky repo lacking a delegator. Never modifies an existing
# hook (it may be tracked and team-owned) — just warns. Called by review-loop at
# Step 0.
set -euo pipefail

hp=$(git config --get core.hooksPath 2>/dev/null || true)
case "$hp" in
	*.husky*) ;;      # husky points core.hooksPath into .husky/_
	*) exit 0 ;;      # not a husky repo — the global hook already runs
esac

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -d "$root/.husky" ] || exit 0

# ponytail: --git-common-dir, not "$root/.git" — in a worktree that's a file, and
# mkdir -p on it dies with "Not a directory". The exclude is repo-wide anyway.
excl="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$excl")"

# install <hook-name> <absolute script path> <what it does>
install_delegator() {
	local name="$1" script="$2" what="$3"
	local hook="$root/.husky/$name"

	if [ -f "$hook" ]; then
		grep -qF "$(basename "$script")" "$hook" && return 0   # already delegating — done
		echo "review-gate: $root/.husky/$name exists without the $what line; add it by hand if you want it here" >&2
		return 0
	fi

	{
		echo '#!/usr/bin/env sh'
		echo "# Personal review-loop $what (local, untracked). Delegates to the global"
		echo '# script; no-ops if that is absent (e.g. on a teammate machine).'
		echo "[ -x \"$script\" ] && \"$script\" \"\$@\""
	} > "$hook"
	chmod +x "$hook"

	# Keep it out of git tracking/status via the repo-local exclude.
	grep -qxF ".husky/$name" "$excl" 2>/dev/null || echo ".husky/$name" >> "$excl"
	echo "review-gate: added untracked .husky/$name delegator in $root"
}

install_delegator pre-push     "$HOME/.git-hooks/review-gate.sh" gate
install_delegator post-rewrite "$HOME/.claude/skills/review-loop/carry-review.sh" "review-record carry"
