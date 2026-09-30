#!/bin/bash
# review-stats.py reports the review cadence, so its failure mode is a number that
# looks like more review happened than did. The headline splits every run into four
# buckets; this pins that they partition the set and that a `carried` row — a rebase
# moving an existing record, not a review pass — is never counted as one.
#   ./review-stats.test.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 1
PY=$(command -v python3.14 || command -v python3)
fails=0
ok() { echo "  ok  $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-stats-test.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export REVIEW_LOOP_RUNS="$TMP/runs.jsonl"
# Isolation is the whole premise: without it these assertions read the live store
# and pass or fail on whatever happens to be recorded there.
[ "$TMP" != "/" ] && [ -d "$TMP" ] || { echo "setup failed: bad temp dir"; exit 1; }

row() { printf '%s\n' "$1" >> "$REVIEW_LOOP_RUNS"; }
# two finished, one abandoned, one still open, three carried
row '{"run_id":"a1","phase":"plan","planned_at":"2026-01-01T00:00:00","session_id":"s1","repo":"r"}'
row '{"run_id":"a1","phase":"finish","outcome":"clean","tier_executed":"full"}'
row '{"run_id":"a2","phase":"plan","planned_at":"2026-01-02T00:00:00","session_id":"s1","repo":"r"}'
row '{"run_id":"a2","phase":"finish","outcome":"cycle-limit","tier_executed":"partial"}'
row '{"run_id":"a3","phase":"plan","planned_at":"2026-01-03T00:00:00","session_id":"s1","repo":"r"}'
row '{"run_id":"a3","phase":"finish","outcome":"abandoned"}'
row '{"run_id":"a4","phase":"plan","planned_at":"2026-01-04T00:00:00","session_id":"s9","repo":"r"}'
for i in 1 2 3; do
	row "{\"run_id\":\"c$i\",\"phase\":\"plan\",\"planned_at\":\"2026-01-0${i}T12:00:00\",\"outcome\":\"carried\",\"tier_executed\":\"carried\",\"repo\":\"r\"}"
done

# CLAUDE_CODE_SESSION_ID=s1 makes a4 (session s9) derivably abandoned; without it
# the reader cannot tell dead from in-flight and reports it as open instead.
out=$(CLAUDE_CODE_SESSION_ID=s1 "$PY" review-stats.py 2>&1)
head=$(head -1 <<<"$out")

n() { sed -E "s/.*$1: ([0-9]+).*/\1/" <<<"$head"; }
runs=$(n "runs"); fin=$(n "finished"); lost=$(n "abandoned")
open_n=$(sed -E 's/.*\(this session\): ([0-9]+).*/\1/' <<<"$head")
carried=$(sed -E 's/.*not a review\): ([0-9]+).*/\1/' <<<"$head")

[ "$runs" = "7" ] && ok "every run is counted once in the total" || bad "total is 7 (got: $head)"
# The bug this pins: a carried row has an outcome, so the obvious `outcome and not
# abandoned` test counts it as a completed review and inflates the cadence.
[ "$fin" = "2" ] && ok "carried rows are not counted as finished reviews" || bad "finished is 2, not inflated by the 3 carried rows (got: $head)"
[ "$carried" = "3" ] && ok "carried rows are reported on their own" || bad "carried is reported separately (got: $head)"
[ "$lost" = "2" ] && ok "explicit and derived abandonment both counted" || bad "abandoned is 2 (got: $head)"
[ "$open_n" = "0" ] && ok "nothing is left over as open" || bad "open is 0 (got: $head)"
# Partition: the four buckets must sum to the total, or a run is double-counted
# or lost — either way the headline is describing a set that does not exist.
[ $((fin + lost + open_n + carried)) -eq "$runs" ] \
	&& ok "the four buckets partition the run set" || bad "the four buckets partition the run set (got: $head)"
# A carried row must still be visible in the per-outcome tally; excluding it from
# the headline is meant to stop it masquerading as a review, not to hide it.
grep -q 'carried=3' <<<"$out" && ok "the outcome tally still shows carried" || bad "the outcome tally still shows carried"

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit "$fails"
