#!/usr/bin/env bash
# looper-check.test.sh — looper-check.sh passes a build of HEAD's looper and refuses the rest.
# Builds into a temp dir; never touches ~/.local/bin.
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
pkg=$(git -C "$here" rev-parse --show-toplevel)/packages/looper
tmp=$(mktemp -d "${TMPDIR:-/tmp}/looper-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export GOCACHE=${GOCACHE:-$tmp/gocache}
# The suites job has no go; review-loop.yml's trust job runs this with go and fails on this line.
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
	check "looper source dirty" 1 "uncommitted changes"
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
exit $((fails > 0))
