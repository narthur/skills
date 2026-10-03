#!/bin/bash
# record-skipped.sh had no test, and cycle 2's drop_sha() refactor silently broke
# its ordinary re-record path under set -e. These are the paths that matter:
# recording, re-recording, and refusing.
#   ./record-skipped.test.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/record-skipped-test.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0
checks=0
ok() { echo "  ok  $1"; checks=$((checks + 1)); }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); checks=$((checks + 1)); }

SCRIPT="$PWD/record-skipped.sh"
repo="$TMP/repo"; mkdir -p "$repo"
# core.hooksPath=/dev/null: the global pre-commit hook (ggshield) fails TLS in
# the sandbox, and this fixture repo has no business running it.
git init -q "$repo"
git -C "$repo" -c core.hooksPath=/dev/null commit -q --allow-empty -m x
sha=$(git -C "$repo" rev-parse HEAD)
STORE="$TMP/home/.claude/review-loop/skipped-shas"
run() { (cd "$repo" && HOME="$TMP/home" REVIEW_LOOP_RUNS="$TMP/runs.jsonl" "$SCRIPT" "$@"); }

run "docs-only, 4 lines" >/dev/null 2>&1 \
	&& ok "records a skip" || bad "records a skip"
grep -q "docs-only, 4 lines" "$STORE" 2>/dev/null \
	&& ok "the reason reaches the store" || bad "the reason reaches the store"

# The store now holds exactly one line, and it is the one being replaced — so
# grep -v filters everything and exits 1. Under set -e that aborted the script.
run "docs-only, then a config line too" >/dev/null 2>&1 \
	&& ok "re-recording the only sha in the store succeeds" \
	|| bad "re-recording the only sha in the store succeeds"
grep -q "then a config line too" "$STORE" 2>/dev/null \
	&& ok "the re-recorded reason replaced the old one" || bad "the re-recorded reason replaced the old one"
[ "$(grep -c "^$sha" "$STORE" 2>/dev/null || echo 0)" -eq 1 ] \
	&& ok "one line per sha, not two" || bad "one line per sha, not two"

# A refused reason must clear neither store.
run "matches an existing pattern in the repo" >/dev/null 2>&1
[ $? -ne 0 ] && ok "a precedent reason is refused" || bad "a precedent reason is refused"
grep -q "matches an existing pattern" "$STORE" 2>/dev/null \
	&& bad "a refused reason must not reach the store" || ok "a refused reason does not reach the store"
# A refused reason must leave the PRIOR record intact — refusing after rewriting
# the line would silently revoke a skip that was already legitimately granted.
grep -q "then a config line too" "$STORE" 2>/dev/null \
	&& ok "a refusal leaves the prior record intact" || bad "a refusal leaves the prior record intact"

run "" >/dev/null 2>&1
[ $? -ne 0 ] && ok "an empty reason is refused" || bad "an empty reason is refused"

echo
# An assertion that VANISHES is invisible without a count. Two ways it has happened
# here: a syntax error inside a `cond && ok || bad` list abandons the whole list so
# NEITHER branch runs, and assertions appended below this summary never execute at all
# (six did, once). shellcheck flags the idiom ~109 times across these suites and cannot
# tell a deliberate one from a broken one — this can.
#
# Raise EXPECTED_CHECKS deliberately when you add an assertion. That edit is the review
# trail, the same way the mutation-catalog floor works.
EXPECTED_CHECKS=9
if [ "$checks" -ne "$EXPECTED_CHECKS" ]; then
	echo "ran $checks checks, expected $EXPECTED_CHECKS — an assertion vanished, or one was added without raising EXPECTED_CHECKS"
	fails=$((fails + 1))
fi
[ "$fails" -eq 0 ] && echo "all checks passed ($checks checks)" || echo "$fails check(s) failed"
exit "$fails"
