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
# two finished, one abandoned, one abandoned-by-derivation, one open with no session,
# two skipped, three carried
row '{"run_id":"a1","phase":"plan","planned_at":"2026-01-01T00:00:00","session_id":"s1","repo":"r"}'
row '{"run_id":"a1","phase":"finish","outcome":"clean","tier_executed":"full"}'
row '{"run_id":"a2","phase":"plan","planned_at":"2026-01-02T00:00:00","session_id":"s1","repo":"r"}'
row '{"run_id":"a2","phase":"finish","outcome":"cycle-limit","tier_executed":"partial"}'
row '{"run_id":"a3","phase":"plan","planned_at":"2026-01-03T00:00:00","session_id":"s1","repo":"r"}'
row '{"run_id":"a3","phase":"finish","outcome":"abandoned"}'
row '{"run_id":"a4","phase":"plan","planned_at":"2026-01-04T00:00:00","session_id":"s9","repo":"r"}'
# session_id null: a headless run names no session. Unknown is not dead — guessing
# here reported every one of them abandoned and tripped the Step 0 alarm.
row '{"run_id":"a5","phase":"plan","planned_at":"2026-01-05T00:00:00","session_id":null,"repo":"r"}'
# `skipped` has the same shape as `carried`: an outcome, and no review behind it.
# Written as the TWO rows runlog.py skipped actually emits, not one row carrying a
# plan phase and an outcome together — a shape runlog never writes.
for i in 1 2; do
	row "{\"run_id\":\"k$i\",\"phase\":\"plan\",\"planned_at\":\"2026-01-0${i}T06:00:00\",\"session_id\":\"s1\",\"repo\":\"r\"}"
	row "{\"run_id\":\"k$i\",\"phase\":\"finish\",\"outcome\":\"skipped\",\"tier_executed\":\"skipped\"}"
done
# Finish-only, as runlog.py carried writes them — no plan row to merge with. This is
# the path every real carried row takes.
for i in 1 2 3; do
	row "{\"run_id\":\"c$i\",\"phase\":\"finish\",\"outcome\":\"carried\",\"tier_executed\":\"carried\",\"repo\":\"r\"}"
done

# CLAUDE_CODE_SESSION_ID=s1 makes a4 (session s9) derivably abandoned; without it
# the reader cannot tell dead from in-flight and reports it as open instead.
out=$(CLAUDE_CODE_SESSION_ID=s1 "$PY" review-stats.py 2>&1)
head=$(head -1 <<<"$out")

n() { sed -E "s/.*$1: ([0-9]+).*/\1/" <<<"$head"; }
runs=$(n "runs"); fin=$(n "finished"); lost=$(n "abandoned")
open_n=$(sed -E 's/.*\(this session\): ([0-9]+).*/\1/' <<<"$head")
skipped=$(sed -E 's/.*skipped \(judged beneath the loop, not a review\): ([0-9]+).*/\1/' <<<"$head")
carried=$(sed -E 's/.*carried \(rebase bookkeeping, not a review\): ([0-9]+).*/\1/' <<<"$head")

# A missed `sed` leaves the subject untouched, so the variable holds the whole
# headline. The equality checks below would fail loudly, but the arithmetic one is
# a bash syntax error that abandons its `&& ok || bad` list entirely — no ok, no
# bad, no increment. Prove every extraction is a number first, or the suite can
# report success while silently measuring one thing fewer.
for v in "$runs" "$fin" "$lost" "$open_n" "$skipped" "$carried"; do
	case $v in
		'' | *[!0-9]*) bad "headline format changed — the numbers could not be parsed (got: $head)"; break ;;
	esac
done

[ "$runs" = "10" ] && ok "every run is counted once in the total" || bad "total is 10 (got: $head)"
# The bug this pins: a carried row has an outcome, so the obvious `outcome and not
# abandoned` test counts it as a completed review and inflates the cadence.
[ "$fin" = "2" ] && ok "carried rows are not counted as finished reviews" || bad "finished is 2, not inflated by the 3 carried rows (got: $head)"
[ "$carried" = "3" ] && ok "carried rows are reported on their own" || bad "carried is reported separately (got: $head)"
[ "$skipped" = "2" ] && ok "skipped rows are reported on their own" || bad "skipped is reported separately (got: $head)"
[ "$lost" = "2" ] && ok "explicit and derived abandonment both counted" || bad "abandoned is 2 (got: $head)"
# The null-session row, and only it. A row that named no session is unknown, not
# dead: reporting it abandoned is the falsehood deriving-on-read exists to avoid.
[ "$open_n" = "1" ] && ok "a run that named no session is open, not abandoned" || bad "open is 1 (got: $head)"
# Partition: the four buckets must sum to the total, or a run is double-counted
# or lost — either way the headline is describing a set that does not exist.
[ $((fin + lost + open_n + skipped + carried)) -eq "$runs" ] \
	&& ok "the buckets partition the run set" || bad "the buckets partition the run set (got: $head)"
# A carried row must still be visible in the per-outcome tally; excluding it from
# the headline is meant to stop it masquerading as a review, not to hide it.
grep -qE '^outcome:.*carried=3' <<<"$out" && ok "the outcome tally still shows carried" || bad "the outcome tally still shows carried"

# --- the spend figures must divide one population by itself. Summing cycle agents over ALL
# --- runs while dividing by FINISHED ones put open, abandoned and bookkeeping runs in the
# --- numerator only: measured, one finished run of 4 agents beside an in-flight run of 20
# --- reported "mean agents/run: 24.0" where the honest figure is 4.0. These are the two
# --- numbers the block exists to let the agent cap be chosen from.
export REVIEW_LOOP_RUNS="$TMP/spend.jsonl"
rm -f "$REVIEW_LOOP_RUNS"
GATES='{"threat_model":{"planned":"run","reason":"2 stale claims"}}' 
fin=$("$PY" runlog.py plan --tier full --model m --gates "$GATES" 2>/dev/null | tail -1)
"$PY" runlog.py cycle --run-id "$fin" --n 1 --applied 1 --agents 4 --tokens 400000 >/dev/null 2>&1
"$PY" runlog.py finish --run-id "$fin" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"done"}}' >/dev/null 2>&1
open=$("$PY" runlog.py plan --tier full --model m --gates "$GATES" 2>/dev/null | tail -1)
"$PY" runlog.py cycle --run-id "$open" --n 1 --applied 1 --agents 20 >/dev/null 2>&1
rep=$("$PY" review-stats.py 2>/dev/null)
grep -q 'mean agents/run: 4.0' <<<"$rep" \
	&& ok "spend divides finished-run cycles by finished runs" \
	|| bad "spend divides finished-run cycles by finished runs (got: $(grep -o 'mean agents/run: [0-9.]*' <<<"$rep"))"
grep -q 'mean tokens/agent: 100,000' <<<"$rep" \
	&& ok "and tokens per agent comes from the same population" \
	|| bad "and tokens per agent comes from the same population (got: $(grep -o 'mean tokens/agent: [0-9,]*' <<<"$rep"))"

echo
# --- The alarm's two signals, and the abandonment double-count ------------------
#
# None of this was covered. The alarm had no test at all, and it was reporting five
# misses of record_reviewed where one was real: two were correct skips on
# unconverged runs, and two came from abandoned runs, each of which contributes
# EVERY planned gate at once. Silence is also what a broken alarm produces, so these
# pin that it still fires — and with which message.
ALARM_TMP="$TMP/alarm"
mkdir -p "$ALARM_TMP"
alarm() { REVIEW_LOOP_RUNS="$ALARM_TMP/$1.jsonl" "$PY" review-stats.py --alarm 2>&1; }
arow() { printf '%s\n' "$2" >> "$ALARM_TMP/$1.jsonl"; }

# Three runs that left a planned gate unreported: a gate to FIX.
for i in 1 2 3; do
	arow drop "{\"run_id\":\"d$i\",\"phase\":\"plan\",\"planned_at\":\"2026-02-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"record_reviewed\":{\"planned\":\"run\"}}}"
	arow drop "{\"run_id\":\"d$i\",\"phase\":\"finish\",\"outcome\":\"clean\",\"executed\":{}}"
done
out=$(alarm drop)
grep -q "record_reviewed did not complete 3x" <<<"$out" \
	&& ok "three unreported runs raise the gate" || bad "three unreported runs raise the gate"

# Three runs that deliberately skipped it: a PLAN to change, and it must say so
# differently — this is the case that was being reported as "did not complete".
for i in 1 2 3; do
	arow skip "{\"run_id\":\"s$i\",\"phase\":\"plan\",\"planned_at\":\"2026-02-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"record_reviewed\":{\"planned\":\"run\",\"reason\":\"on clean exit\"}}}"
	arow skip "{\"run_id\":\"s$i\",\"phase\":\"finish\",\"outcome\":\"cycle-limit\",\"executed\":{\"record_reviewed\":{\"status\":\"skipped\",\"reason\":\"run did not converge\"}}}"
done
out=$(alarm skip)
grep -q "record_reviewed was skipped though the plan said run 3x" <<<"$out" \
	&& ok "three deliberate skips raise the plan, not the gate" \
	|| bad "three deliberate skips raise the plan, not the gate"
grep -q "did not complete" <<<"$out" \
	&& bad "a deliberate skip is still reported as a failure to complete" \
	|| ok "a deliberate skip is not reported as a failure to complete"

# Three abandoned runs, nine planned gates each. The abandonment is the signal; the
# per-gate attribution is noise, and counting both turned one event into nine.
for i in 1 2 3; do
	arow aband "{\"run_id\":\"x$i\",\"phase\":\"plan\",\"planned_at\":\"2026-02-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"record_reviewed\":{\"planned\":\"run\"},\"learnings_capture\":{\"planned\":\"run\"},\"upstream_drift_check\":{\"planned\":\"run\"}}}"
	arow aband "{\"run_id\":\"x$i\",\"phase\":\"finish\",\"outcome\":\"abandoned\"}"
done
out=$(alarm aband)
grep -q "(run abandoned) did not complete 3x" <<<"$out" \
	&& ok "repeated abandonment raises" || bad "repeated abandonment raises"
grep -qE "record_reviewed|learnings_capture|upstream_drift_check" <<<"$out" \
	&& bad "an abandoned run is counted again against each of its gates" \
	|| ok "an abandoned run is not counted again against each of its gates"

# And the shape that was firing falsely: two correct skips plus one real miss of the
# same gate is below the threshold in BOTH buckets, so it must stay silent.
for i in 1 2; do
	arow mixed "{\"run_id\":\"m$i\",\"phase\":\"plan\",\"planned_at\":\"2026-02-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"record_reviewed\":{\"planned\":\"run\"}}}"
	arow mixed "{\"run_id\":\"m$i\",\"phase\":\"finish\",\"outcome\":\"cycle-limit\",\"executed\":{\"record_reviewed\":{\"status\":\"skipped\"}}}"
done
arow mixed '{"run_id":"m3","phase":"plan","planned_at":"2026-02-03T00:00:00","session_id":"s1","repo":"r","gates":{"record_reviewed":{"planned":"run"}}}'
arow mixed '{"run_id":"m3","phase":"finish","outcome":"clean","executed":{"record_reviewed":{"status":"pending"}}}'
out=$(alarm mixed)
[ -z "$out" ] && ok "two correct skips plus one real miss stays silent" \
	|| bad "two correct skips plus one real miss stays silent"

[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit "$fails"
