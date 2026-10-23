#!/usr/bin/env bash
# looper-check.sh — exit 0 only if ~/.local/bin/looper was built from the looper source
# this checkout's HEAD holds (packages/looper), so the skill and the binary it drives come
# from the same commit. On any mismatch it names the cause and the command that rebuilds it.
#
# "The same source" is the git tree of packages/looper, compared at the commit go stamped
# into the binary (vcs.revision) and at HEAD. A commit elsewhere in the repo leaves that tree
# alone and needs no rebuild; any change to looper does, on whichever branch it landed.
set -u
LOOPER=${LOOPER:-$HOME/.local/bin/looper}
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null) || {
	echo "review-loop: $(dirname "$0") is not inside a git checkout, so there is no packages/looper to build looper from; link the skill from a checkout of narthur/skills" >&2
	exit 1
}
pkg=$root/packages/looper
fail() {
	echo "review-loop: $1. Rebuild it from this checkout: (cd '$pkg' && GOBIN=~/.local/bin go install ./cmd/looper)" >&2
	exit 1
}
[ -x "$LOOPER" ] || fail "$LOOPER is missing"
# go, not the shell, from inside the package: under asdf go resolves only where a version is pinned.
info=$(cd "$pkg" && go version -m "$LOOPER" 2>&1) || fail "go version -m could not read $LOOPER: $info"
have=$(sed -n 's/.*[[:space:]]vcs\.revision=//p' <<<"$info")
[ -n "$have" ] || fail "$LOOPER carries no commit (an @version install, or built with -buildvcs=false)"
# Not vcs.modified: go sets it for any untracked file anywhere in the repo, so it would refuse
# nearly every build. ponytail: a build of an edit later reverted passes; nothing tracks that.
[ -z "$(git -C "$pkg" status --porcelain -- .)" ] \
	|| fail "packages/looper has uncommitted or untracked files (an untracked .go file compiles in), so no build matches HEAD's looper; commit or drop them, a rebuild will not help"
built=$(git -C "$root" rev-parse -q --verify "$have:packages/looper" 2>/dev/null) \
	|| fail "$LOOPER was built at ${have:0:12}, a commit this checkout does not have or that holds no packages/looper"
[ "$built" = "$(git -C "$root" rev-parse HEAD:packages/looper)" ] \
	|| fail "$LOOPER was built at ${have:0:12}, whose looper differs from HEAD's"
