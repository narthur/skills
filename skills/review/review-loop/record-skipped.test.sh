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

# An empty reason is refused before anything else is consulted, looper included.
run "" >/dev/null 2>&1
[ $? -ne 0 ] && ok "an empty reason is refused" || bad "an empty reason is refused"

# No looper is a refusal, not a quieter skip. This used to be `if [ -f "$RUNLOG" ]`: with
# the writer absent the sha was stamped skipped and the run record never heard of it, the
# same unexplained gate-clear this script exists to replace. The fixture HOME has no
# ~/.local/bin/looper yet.
out=$(run "docs-only, 4 lines" 2>&1)
[ $? -eq 1 ] && ok "no looper refuses the skip" || bad "no looper refuses the skip (got: $out)"
[ ! -s "$STORE" ] && ok "and writes nothing to skipped-shas" || bad "and writes nothing to skipped-shas"
grep -q "go install github.com/pinepeakdigital/looper/cmd/looper@" <<<"$out" \
	&& ok "and names the install command" || bad "and names the install command (got: $out)"

# The rest records through the real writer. CI's trust job runs this suite with looper on
# PATH and requires the skip line to be absent.
looper_checks=0
if real_looper=$(command -v looper); then
	looper_checks=8
	mkdir -p "$TMP/home/.local/bin" && ln -s "$real_looper" "$TMP/home/.local/bin/looper"

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
else
	echo "  skip  looper not on PATH — the recording checks did not run"
fi

echo
# An assertion that VANISHES is invisible without a count. Two ways it has happened
# here: a syntax error inside a `cond && ok || bad` list abandons the whole list so
# NEITHER branch runs, and assertions appended below this summary never execute at all
# (six did, once). shellcheck flags the idiom ~109 times across these suites and cannot
# tell a deliberate one from a broken one — this can.
#
# Raise EXPECTED_CHECKS deliberately when you add an assertion. That edit is the review
# trail, the same way the mutation-catalog floor works.
EXPECTED_CHECKS=4
if [ "$checks" -ne $((EXPECTED_CHECKS + looper_checks)) ]; then
	echo "ran $checks checks, expected $((EXPECTED_CHECKS + looper_checks)) — an assertion vanished, or one was added without raising EXPECTED_CHECKS"
	fails=$((fails + 1))
fi
[ "$fails" -eq 0 ] && echo "all checks passed ($checks checks)" || echo "$fails check(s) failed"
exit "$fails"
