#!/usr/bin/env bash
# looper-check.test.sh — looper-check.sh passes a build of HEAD's looper and refuses the rest.
# Builds into a temp dir; never touches ~/.local/bin.
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
pkg=$(git -C "$here" rev-parse --show-toplevel)/packages/looper
tmp=$(mktemp -d "${TMPDIR:-/tmp}/looper-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export GOCACHE=${GOCACHE:-$tmp/gocache}
# The suites job has no go, so it skips here; review-loop.yml's trust job has go and runs it all.
command -v go >/dev/null || { echo "skip  looper-check: go is not on PATH"; exit 0; }
fails=0
check() { # name, expected exit (0|1), stderr substring or ""
	out=$(LOOPER=$tmp/looper bash "$here/looper-check.sh" 2>&1); rc=$?
	if [ "$rc" -ne "$2" ] || { [ -n "$3" ] && ! grep -q "$3" <<<"$out"; }; then
		echo "FAIL $1: exit $rc: $out"; fails=$((fails + 1))
	else echo "ok  $1"; fi
}

check "missing binary" 1 "is missing"
(cd "$pkg" && go build -buildvcs=false -o "$tmp/looper" ./cmd/looper) || exit 1
check "no commit stamped" 1 "carries no commit"
(cd "$pkg" && go build -o "$tmp/looper" ./cmd/looper) || exit 1
stamped=$(cd "$pkg" && go version -m "$tmp/looper" | sed -n 's/.*[[:space:]]vcs\.revision=//p')
if [ -n "$(git -C "$pkg" status --porcelain -- .)" ]; then
	check "looper source dirty" 1 "uncommitted or untracked"
elif [ "$stamped" != "$(git -C "$pkg" rev-parse HEAD)" ]; then
	# go finds the repo by a .git directory, so in a worktree nested inside another checkout it
	# stamps that checkout's HEAD. Installs run from the main checkout, where this cannot happen.
	echo "skip  built from HEAD: go stamped ${stamped:0:12}, not this worktree's HEAD (nested worktree)"
else
	check "built from HEAD" 0 ""
fi
# A file go cannot read build info from.
printf '#!/bin/sh\n' >"$tmp/looper"; chmod +x "$tmp/looper"
check "not a go binary" 1 "could not read"

# A build of HEAD, then the two refusals of a build from elsewhere, each built in a clone
# outside this checkout so go stamps the clone's commit; a clone is never nested, so the pass
# case runs even where the one above skips. The refusals need history a shallow checkout lacks.
last=$(git -C "$pkg" log -1 --format=%H -- .)
if [ -n "$(git -C "$pkg" status --porcelain -- .)" ]; then
	echo "skip  clone builds: packages/looper is dirty, which refuses first"
else
	git clone -q --shared "$(git -C "$pkg" rev-parse --show-toplevel)" "$tmp/c" || exit 1
	git -C "$tmp/c" checkout -q "$(git -C "$pkg" rev-parse HEAD)" || exit 1
	(cd "$tmp/c/packages/looper" && go build -o "$tmp/looper" ./cmd/looper) || exit 1
	check "built from HEAD, in a clone" 0 ""
	if git -C "$tmp/c" checkout -q "$last^" 2>/dev/null; then
		(cd "$tmp/c/packages/looper" && go build -o "$tmp/looper" ./cmd/looper) || exit 1
		check "built at an older looper" 1 "differs from HEAD"
		echo "// x" >>"$tmp/c/packages/looper/cmd/looper/main.go"
		git -C "$tmp/c" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -qam x
		(cd "$tmp/c/packages/looper" && go build -o "$tmp/looper" ./cmd/looper) || exit 1
		check "built at a commit this checkout lacks" 1 "does not have"
	else
		echo "skip  older/foreign builds: $last has no parent here (a shallow checkout, or the root commit)"
	fi
fi
exit $((fails > 0))
