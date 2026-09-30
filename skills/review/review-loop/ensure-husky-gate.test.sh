#!/bin/bash
# Self-check for ensure-husky-gate.sh: creates delegator in a husky repo, is
# idempotent, no-ops in non-husky repos, and won't clobber an existing hook.
set -euo pipefail
# Absolute: the tests cd into temp repos, so a $0-relative path breaks after the first cd.
script="$(cd "$(dirname "$0")" && pwd)/ensure-husky-gate.sh"
# ${TMPDIR:-/tmp}: a bare `mktemp -d` is refused under the sandbox, which made
# this test unrunnable there. Matches the other three test files in this dir.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ensure-husky-gate-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- husky repo missing the delegator → creates it, adds to exclude ---
hr="$tmp/husky"; mkdir -p "$hr"; cd "$hr"
git init -q
mkdir -p .husky/_
git config core.hooksPath .husky/_
"$script" >/dev/null
[ -f .husky/pre-push ] || { echo "FAIL: delegator not created"; exit 1; }
grep -q 'review-gate.sh' .husky/pre-push || { echo "FAIL: delegator missing gate call"; exit 1; }
grep -qxF '.husky/pre-push' .git/info/exclude || { echo "FAIL: not excluded"; exit 1; }
[ -x .husky/pre-push ] || { echo "FAIL: not executable"; exit 1; }
# post-rewrite carries a review record across a rebase; husky shadows the global
# hook for it exactly as it does for pre-push, so it needs its own delegator.
[ -f .husky/post-rewrite ] || { echo "FAIL: post-rewrite delegator not created"; exit 1; }
grep -q 'carry-review.sh' .husky/post-rewrite || { echo "FAIL: post-rewrite delegator missing carry call"; exit 1; }
grep -qxF '.husky/post-rewrite' .git/info/exclude || { echo "FAIL: post-rewrite not excluded"; exit 1; }
[ -x .husky/post-rewrite ] || { echo "FAIL: post-rewrite not executable"; exit 1; }

# --- idempotent: second run adds no duplicate exclude line, no change ---
before=$(md5 -q .husky/pre-push 2>/dev/null || md5sum .husky/pre-push)
"$script" >/dev/null
after=$(md5 -q .husky/pre-push 2>/dev/null || md5sum .husky/pre-push)
[ "$before" = "$after" ] || { echo "FAIL: not idempotent (hook changed)"; exit 1; }
[ "$(grep -cxF '.husky/pre-push' .git/info/exclude)" = "1" ] || { echo "FAIL: duplicate exclude line"; exit 1; }
# install_delegator treats both hooks identically, so both need the same checks —
# otherwise a regression in one is invisible while the other's checks stay green.
pr_before=$(md5 -q .husky/post-rewrite 2>/dev/null || md5sum .husky/post-rewrite)
"$script" >/dev/null
pr_after=$(md5 -q .husky/post-rewrite 2>/dev/null || md5sum .husky/post-rewrite)
[ "$pr_before" = "$pr_after" ] || { echo "FAIL: post-rewrite not idempotent"; exit 1; }
[ "$(grep -cxF '.husky/post-rewrite' .git/info/exclude)" = "1" ] || { echo "FAIL: duplicate post-rewrite exclude line"; exit 1; }

# --- non-husky repo → no-op ---
nr="$tmp/plain"; mkdir -p "$nr"; cd "$nr"
git init -q
"$script" >/dev/null
[ ! -e .husky/pre-push ] || { echo "FAIL: created a hook in a non-husky repo"; exit 1; }
[ ! -d .husky ] || { echo "FAIL: touched non-husky repo"; exit 1; }

# --- husky repo with a pre-existing custom hook → left untouched ---
er="$tmp/existing"; mkdir -p "$er/.husky"; cd "$er"
git init -q; git config core.hooksPath .husky/_; mkdir -p .husky/_
printf '#!/bin/sh\necho custom\n' > .husky/pre-push
printf '#!/bin/sh\necho custom-rewrite\n' > .husky/post-rewrite
"$script" 2>/dev/null || true
grep -q 'review-gate.sh' .husky/pre-push && { echo "FAIL: clobbered existing hook"; exit 1; }
grep -q custom .husky/pre-push || { echo "FAIL: lost existing hook content"; exit 1; }
# A team-owned post-rewrite must survive exactly as a team-owned pre-push does.
grep -q 'carry-review.sh' .husky/post-rewrite && { echo "FAIL: clobbered existing post-rewrite"; exit 1; }
grep -q custom-rewrite .husky/post-rewrite || { echo "FAIL: lost existing post-rewrite content"; exit 1; }

echo "ok"
