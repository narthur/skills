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
checks=0
ok() { echo "  ok  $1"; checks=$((checks + 1)); }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); checks=$((checks + 1)); }

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
# The session id is PINNED, not inherited. The w5 case below is abandoned only by
# derivation from the session, and is_abandoned() answers False unconditionally when the
# var is unset — so that assertion passed in an interactive shell (which always exports it)
# and failed under CI, which does not. `env -u CLAUDE_CODE_SESSION_ID` reproduces it. The
# same hazard is already in this repo's learnings from one test earlier.
alarm() { CLAUDE_CODE_SESSION_ID=s1 REVIEW_LOOP_RUNS="$ALARM_TMP/$1.jsonl" "$PY" review-stats.py --alarm 2>&1; }
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
grep -q "record_reviewed was declined with a reason (skipped) 3x" <<<"$out" \
	&& ok "three deliberate skips raise the plan, not the gate" \
	|| bad "three deliberate skips raise the plan, not the gate"
# Guarded on non-empty: an absence assertion is satisfied by output that does not exist,
# so with the alarm printing nothing at all this passed while the positive assertions
# beside it went red. Silence is the alarm's correct state AND its total-failure state,
# which makes a bare `! grep` here the one shape that cannot tell them apart.
[ -n "$out" ] && ! grep -q "did not complete" <<<"$out" \
	&& ok "a deliberate skip is not reported as a failure to complete" \
	|| bad "a deliberate skip is not reported as a failure to complete"

# Three abandoned runs, nine planned gates each. The abandonment is the signal; the
# per-gate attribution is noise, and counting both turned one event into nine.
for i in 1 2 3; do
	arow aband "{\"run_id\":\"x$i\",\"phase\":\"plan\",\"planned_at\":\"2026-02-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"record_reviewed\":{\"planned\":\"run\"},\"learnings_capture\":{\"planned\":\"run\"},\"upstream_drift_check\":{\"planned\":\"run\"}}}"
	arow aband "{\"run_id\":\"x$i\",\"phase\":\"finish\",\"outcome\":\"abandoned\"}"
done
out=$(alarm aband)
grep -q "(run abandoned) did not complete 3x" <<<"$out" \
	&& ok "repeated abandonment raises" || bad "repeated abandonment raises"

# ...and it says WHY, grouped. The count alone is not actionable and reads as broken: five
# abandonments with no reasons shown sent a reader hunting the store by hand, concluding
# the counter was wrong, and nearly softening a correct signal. The reasons are already in
# the record; not printing them was the whole defect.
for i in 1 2 3; do
	arow awhy "{\"run_id\":\"w$i\",\"phase\":\"plan\",\"planned_at\":\"2026-03-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"record_reviewed\":{\"planned\":\"run\"}}}"
	arow awhy "{\"run_id\":\"w$i\",\"phase\":\"finish\",\"outcome\":\"abandoned\",\"abandoned_missing\":\"plan.py re-invoked to re-read its own plan\"}"
done
# A fourth with a DIFFERENT reason, so grouping is visible as grouping.
arow awhy "{\"run_id\":\"w4\",\"phase\":\"plan\",\"planned_at\":\"2026-03-04T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"record_reviewed\":{\"planned\":\"run\"}}}"
arow awhy "{\"run_id\":\"w4\",\"phase\":\"finish\",\"outcome\":\"abandoned\",\"abandoned_missing\":\"agent_7: fast path approved\"}"
# And a fifth nobody recorded at all — the one shape with no reason to print, where
# saying so IS the actionable fact.
arow awhy "{\"run_id\":\"w5\",\"phase\":\"plan\",\"planned_at\":\"2026-03-05T00:00:00\",\"session_id\":\"someone-else\",\"repo\":\"r\",\"gates\":{\"record_reviewed\":{\"planned\":\"run\"}}}"
out=$(alarm awhy)
grep -q " 3x plan.py re-invoked to re-read its own plan" <<<"$out" \
	&& ok "a repeated abandonment reason is grouped and counted" \
	|| bad "a repeated abandonment reason is grouped and counted"
grep -q " 1x agent_7: fast path approved" <<<"$out" \
	&& ok "a distinct abandonment reason is listed separately" \
	|| bad "a distinct abandonment reason is listed separately"
# The inferred one must not borrow another run's reason, which is what a plain
# `.get(reason)` over a shared counter would do.
grep -q "nothing said why" <<<"$out" \
	&& ok "an abandonment with no record says so rather than borrowing a reason" \
	|| bad "an abandonment with no record says so rather than borrowing a reason"
[ -n "$out" ] && ! grep -qE "record_reviewed|learnings_capture|upstream_drift_check" <<<"$out" \
	&& ok "an abandoned run is not counted again against each of its gates" \
	|| bad "an abandoned run is counted again against each of its gates"

# Grouping is on the FLATTENED text, not the raw field. Keying the counter on the raw
# reason and flattening only at print time made three whitespace-variant copies of one
# cause print as three separate `1x` lines — defeating the grouping outright, and able to
# push a repeated cause below ABANDON_REASONS_SHOWN. Operators type this text by hand.
i=0
for variant in "a  double  space" "a double space" "   a double space  "; do
	i=$((i + 1))
	arow aflat "{\"run_id\":\"f$i\",\"phase\":\"plan\",\"planned_at\":\"2026-04-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"record_reviewed\":{\"planned\":\"run\"}}}"
	arow aflat "{\"run_id\":\"f$i\",\"phase\":\"finish\",\"outcome\":\"abandoned\",\"abandoned_missing\":\"$variant\"}"
done
out=$(alarm aflat)
grep -q " 3x a double space" <<<"$out" \
	&& ok "whitespace variants of one reason group as one reason" \
	|| bad "whitespace variants of one reason group as one reason"

# A long reason is clipped in the MIDDLE. Clipping from the end alone printed two reasons
# sharing a long prefix — likely, since these name gates — as identical lines with
# separate counts, which reads as the counter being broken. Nothing asserted the clip at
# all before: removing truncation entirely left this suite green.
pre="record_reviewed and learnings_capture and upstream_drift_check and threat_model_update both planned and"
for i in 1 2 3; do
	arow aclip "{\"run_id\":\"q$i\",\"phase\":\"plan\",\"planned_at\":\"2026-05-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"record_reviewed\":{\"planned\":\"run\"}}}"
	arow aclip "{\"run_id\":\"q$i\",\"phase\":\"finish\",\"outcome\":\"abandoned\",\"abandoned_missing\":\"$pre never reached cycle $i of the fan-out\"}"
done
out=$(alarm aclip)
grep -q "…" <<<"$out" && ok "an overlong reason is clipped" || bad "an overlong reason is clipped"
# The two differ only in their TAIL, so end-clipping alone would print them identically.
clipped=$(grep -c "1x record_reviewed and learnings" <<<"$out")
distinct=$(grep "1x record_reviewed and learnings" <<<"$out" | sort -u | wc -l | tr -d ' ')
[ "$clipped" = "3" ] && [ "$distinct" = "3" ] \
	&& ok "two reasons sharing a long prefix stay distinguishable once clipped" \
	|| bad "two reasons sharing a long prefix stay distinguishable ($clipped shown, $distinct distinct)"
# The reason itself is bounded by REASON_CLIP. Measured in characters, via $PY: the
# ellipsis is three BYTES, so awk's byte-wise length() reports 98 for a correct 96-char
# clip and the check would fail on the thing it is meant to pass.
longest=$($PY -c 'import re,sys; print(max((len(re.sub(r"^ *\d+x ","",l)) for l in sys.stdin.read().splitlines()), default=0))' <<<"$out")
[ "$longest" -le 96 ] \
	&& ok "and the clip actually bounds the reason" \
	|| bad "and the clip actually bounds the reason (longest $longest)"

# More distinct reasons than the alarm shows: the overflow line must name the count and
# point somewhere real. It used to point at `review-stats.py --report`, which argparse
# rejects, and the report printed no reasons at all — a message directing a reader to
# information that did not exist, inside the fix for exactly that defect.
for i in 1 2 3 4 5; do
	arow amany "{\"run_id\":\"n$i\",\"phase\":\"plan\",\"planned_at\":\"2026-06-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"record_reviewed\":{\"planned\":\"run\"}}}"
	arow amany "{\"run_id\":\"n$i\",\"phase\":\"finish\",\"outcome\":\"abandoned\",\"abandoned_missing\":\"cause number $i\"}"
done
out=$(alarm amany)
grep -q "and 2 other reason(s)" <<<"$out" \
	&& ok "the overflow line counts the reasons it is not showing" \
	|| bad "the overflow line counts the reasons it is not showing"
# The pointer has to work. `--report` is not a flag; the bare command is the report.
rep=$(CLAUDE_CODE_SESSION_ID=s1 REVIEW_LOOP_RUNS="$ALARM_TMP/amany.jsonl" "$PY" review-stats.py 2>&1)
grep -q "why runs were abandoned" <<<"$rep" && grep -q "cause number 5" <<<"$rep" \
	&& ok "and the report it points at really lists every reason" \
	|| bad "and the report it points at really lists every reason"

# And the shape that was firing falsely: two correct skips plus one real miss of the
# same gate is below the threshold in BOTH buckets, so it must stay silent.
for i in 1 2; do
	arow mixed "{\"run_id\":\"m$i\",\"phase\":\"plan\",\"planned_at\":\"2026-02-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"record_reviewed\":{\"planned\":\"run\"}}}"
	arow mixed "{\"run_id\":\"m$i\",\"phase\":\"finish\",\"outcome\":\"cycle-limit\",\"executed\":{\"record_reviewed\":{\"status\":\"skipped\"}}}"
done
arow mixed '{"run_id":"m3","phase":"plan","planned_at":"2026-02-03T00:00:00","session_id":"s1","repo":"r","gates":{"record_reviewed":{"planned":"run"}}}'
arow mixed '{"run_id":"m3","phase":"finish","outcome":"clean","executed":{"record_reviewed":{"status":"pending"}}}'
out=$(alarm mixed)
# This is the live store's actual shape, and it was the basis for calling one of the five
# reported misses "real". It is not: `pending` carried the reason "runs immediately after
# this finish, before the push" — deliberate, like the two skips. So all three are
# declines, and three declines of a gate the plan keeps marking "run" is a true signal
# with a specific meaning: change the plan, because `record_reviewed`'s own planned reason
# ("on clean exit") is conditional while the plan records it unconditionally. What must
# never happen is this shape being reported as a failure to COMPLETE.
grep -q "record_reviewed was declined with a reason (pending, skipped) 3x" <<<"$out" \
	&& ok "the live store's shape raises the plan, naming both statuses" \
	|| bad "the live store's shape raises the plan, naming both statuses (got: $out)"
[ -n "$out" ] && ! grep -q "did not complete" <<<"$out" \
	&& ok "and is not reported as a failure to complete" \
	|| bad "and is not reported as a failure to complete"

# Below the threshold in both buckets and combined: genuinely silent.
arow quiet '{"run_id":"q1","phase":"plan","planned_at":"2026-06-01T00:00:00","session_id":"s1","repo":"r","gates":{"record_reviewed":{"planned":"run"}}}'
arow quiet '{"run_id":"q1","phase":"finish","outcome":"cycle-limit","executed":{"record_reviewed":{"status":"skipped","reason":"did not converge"}}}'
arow quiet '{"run_id":"q2","phase":"plan","planned_at":"2026-06-02T00:00:00","session_id":"s1","repo":"r","gates":{"record_reviewed":{"planned":"run"}}}'
arow quiet '{"run_id":"q2","phase":"finish","outcome":"clean","executed":{}}'
[ -z "$(alarm quiet)" ] && ok "one decline plus one drop stays silent" \
	|| bad "one decline plus one drop stays silent"

# `skipped` is not the whole deliberate vocabulary. runlog.cmd_finish requires a reason for
# every status but `done` and never validates the string, and the live record already held
# `pending` and `deferred` alongside `skipped` — all three deliberate. Enumerating the
# deliberate ones put the other two in the failure bucket, which is the very bug this
# alarm change exists to fix, reached by a different spelling.
for st in pending deferred; do
	f="decl-$st"
	for i in 1 2 3; do
		arow "$f" "{\"run_id\":\"p$i\",\"phase\":\"plan\",\"planned_at\":\"2026-03-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"pr_report\":{\"planned\":\"run\"}}}"
		arow "$f" "{\"run_id\":\"p$i\",\"phase\":\"finish\",\"outcome\":\"clean\",\"executed\":{\"pr_report\":{\"status\":\"$st\",\"reason\":\"deliberate and documented\"}}}"
	done
	out=$(alarm "$f")
	grep -q "pr_report was declined with a reason ($st) 3x" <<<"$out" \
		&& ok "a '$st' gate is declined, not reported as a failure" \
		|| bad "a '$st' gate is declined, not reported as a failure"
	[ -n "$out" ] && ! grep -q "did not complete" <<<"$out" \
		&& ok "and '$st' is not counted as a failure to complete" \
		|| bad "and '$st' is not counted as a failure to complete"
done

# A status that says it FAILED is a failure, not a decline — the inverted list must not
# swallow the one case it exists to report.
for i in 1 2 3; do
	arow failed "{\"run_id\":\"f$i\",\"phase\":\"plan\",\"planned_at\":\"2026-03-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"security_review\":{\"planned\":\"run\"}}}"
	arow failed "{\"run_id\":\"f$i\",\"phase\":\"finish\",\"outcome\":\"clean\",\"executed\":{\"security_review\":{\"status\":\"failed\",\"reason\":\"agent errored\"}}}"
done
out=$(alarm failed)
grep -q "security_review did not complete (failed) 3x" <<<"$out" \
	&& ok "a failed gate is still a failure to complete" || bad "a failed gate is still a failure to complete"

# A gate that fails BOTH ways must still raise. Two of each is four non-completions, and
# thresholding the buckets independently alone left that silent — the split exists to name
# the right fix, not to make a thrashing gate cheaper to ignore.
for i in 1 2; do
	arow both "{\"run_id\":\"b$i\",\"phase\":\"plan\",\"planned_at\":\"2026-04-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"evidence_gate\":{\"planned\":\"run\"}}}"
	arow both "{\"run_id\":\"b$i\",\"phase\":\"finish\",\"outcome\":\"clean\",\"executed\":{}}"
	arow both "{\"run_id\":\"c$i\",\"phase\":\"plan\",\"planned_at\":\"2026-04-1${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"evidence_gate\":{\"planned\":\"run\"}}}"
	arow both "{\"run_id\":\"c$i\",\"phase\":\"finish\",\"outcome\":\"clean\",\"executed\":{\"evidence_gate\":{\"status\":\"skipped\",\"reason\":\"no PR\"}}}"
done
out=$(alarm both)
grep -q "evidence_gate did not complete 2x and was declined 2x, in varying ways" <<<"$out" \
	&& ok "a gate failing both ways still raises" || bad "a gate failing both ways still raises"

# The printed order reads as a ranking, so it must be one across both buckets: two
# separately-sorted lists concatenated put a 3x drop above a 6x decline.
for i in 1 2 3; do
	arow sort "{\"run_id\":\"g$i\",\"phase\":\"plan\",\"planned_at\":\"2026-05-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"aaa_drop\":{\"planned\":\"run\"},\"zzz_declined\":{\"planned\":\"run\"}}}"
	arow sort "{\"run_id\":\"g$i\",\"phase\":\"finish\",\"outcome\":\"clean\",\"executed\":{\"zzz_declined\":{\"status\":\"skipped\",\"reason\":\"r\"}}}"
done
for i in 4 5 6; do
	arow sort "{\"run_id\":\"g$i\",\"phase\":\"plan\",\"planned_at\":\"2026-05-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"zzz_declined\":{\"planned\":\"run\"}}}"
	arow sort "{\"run_id\":\"g$i\",\"phase\":\"finish\",\"outcome\":\"clean\",\"executed\":{\"zzz_declined\":{\"status\":\"skipped\",\"reason\":\"r\"}}}"
done
first=$(alarm sort | sed -n '2p')
grep -q "zzz_declined" <<<"$first" \
	&& ok "the more frequent offender is listed first across both buckets" \
	|| bad "the more frequent offender is listed first across both buckets (got: $first)"


# Neither vocabulary is closed: runlog never validates the status string. The question is
# which way an UNRECOGNISED one defaults, and it must default loud — a spelling nobody
# listed is far likelier to be a new failure or a bug than a new deliberate word. Listing
# the failures instead put every one of these in the benign bucket.
for st in error timeout crashed blocked incomplete FAILED; do
	f="vocab-$st"
	for i in 1 2 3; do
		arow "$f" "{\"run_id\":\"v$i\",\"phase\":\"plan\",\"planned_at\":\"2026-07-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"g\":{\"planned\":\"run\"}}}"
		arow "$f" "{\"run_id\":\"v$i\",\"phase\":\"finish\",\"outcome\":\"clean\",\"executed\":{\"g\":{\"status\":\"$st\",\"reason\":\"r\"}}}"
	done
	out=$(alarm "$f")
	grep -q "g did not complete ($st) 3x" <<<"$out" \
		&& ok "an unrecognised status '$st' goes loud and is named" \
		|| bad "an unrecognised status '$st' goes loud and is named (got: $out)"
done

# A non-string status is not rejected at write time either, and formatting one into the
# message crashed cmd_alarm with a TypeError — taking down every gate's signal at once,
# which is the silence failure mode reached by a different route.
for i in 1 2 3; do
	arow nonstr "{\"run_id\":\"n$i\",\"phase\":\"plan\",\"planned_at\":\"2026-08-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"g\":{\"planned\":\"run\"}}}"
	arow nonstr "{\"run_id\":\"n$i\",\"phase\":\"finish\",\"outcome\":\"clean\",\"executed\":{\"g\":{\"status\":123,\"reason\":\"r\"}}}"
done
out=$(alarm nonstr)
grep -q "g did not complete (123) 3x" <<<"$out" \
	&& ok "a non-string status neither crashes nor is softened" \
	|| bad "a non-string status neither crashes nor is softened (got: $out)"

# A gate over the threshold in BOTH buckets prints one line per bucket, each count real.
# Pinned because the "both ways" case above only covers neither bucket reaching it.
for i in 1 2 3; do
	arow twice "{\"run_id\":\"t$i\",\"phase\":\"plan\",\"planned_at\":\"2026-09-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"g\":{\"planned\":\"run\"}}}"
	arow twice "{\"run_id\":\"t$i\",\"phase\":\"finish\",\"outcome\":\"clean\",\"executed\":{}}"
	arow twice "{\"run_id\":\"u$i\",\"phase\":\"plan\",\"planned_at\":\"2026-09-1${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"g\":{\"planned\":\"run\"}}}"
	arow twice "{\"run_id\":\"u$i\",\"phase\":\"finish\",\"outcome\":\"clean\",\"executed\":{\"g\":{\"status\":\"skipped\",\"reason\":\"r\"}}}"
done
out=$(alarm twice)
grep -q "g did not complete 3x" <<<"$out" && grep -q "g was declined with a reason (skipped) 3x" <<<"$out" \
	&& ok "a gate over both thresholds reports each bucket once" \
	|| bad "a gate over both thresholds reports each bucket once (got: $out)"
! grep -q "varying ways" <<<"$out" \
	&& ok "and does not also print the combined line" \
	|| bad "and does not also print the combined line"

# `waived` is documented as a real outcome — references/measurement-gate.md:65, "A waiver
# passes the gate" — and was missing from the allowlist, so a waived measurement gate read
# as a failure to complete. Third occurrence of the same decision going wrong, this time
# as an omission rather than a wrong side.
for i in 1 2 3; do
	arow waived "{\"run_id\":\"w$i\",\"phase\":\"plan\",\"planned_at\":\"2026-10-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"measurement_gate\":{\"planned\":\"run\"}}}"
	arow waived "{\"run_id\":\"w$i\",\"phase\":\"finish\",\"outcome\":\"clean\",\"executed\":{\"measurement_gate\":{\"status\":\"waived\",\"reason\":\"repo cannot measure this\"}}}"
done
out=$(alarm waived)
grep -q "measurement_gate was declined with a reason (waived) 3x" <<<"$out" \
	&& ok "a waived gate is declined, not reported as a failure" \
	|| bad "a waived gate is declined, not reported as a failure (got: $out)"

# And `blocked` stays loud: references/evidence-gate.md treats a blocked gate as a real
# problem, so the asymmetry with `waived` is deliberate and needs pinning.
for i in 1 2 3; do
	arow blocked "{\"run_id\":\"bl$i\",\"phase\":\"plan\",\"planned_at\":\"2026-11-0${i}T00:00:00\",\"session_id\":\"s1\",\"repo\":\"r\",\"gates\":{\"evidence_gate\":{\"planned\":\"run\"}}}"
	arow blocked "{\"run_id\":\"bl$i\",\"phase\":\"finish\",\"outcome\":\"clean\",\"executed\":{\"evidence_gate\":{\"status\":\"blocked\",\"reason\":\"gap\"}}}"
done
grep -q "evidence_gate did not complete (blocked) 3x" <<<"$(alarm blocked)" \
	&& ok "a blocked gate is still loud" || bad "a blocked gate is still loud"

# An assertion that VANISHES is invisible without a count. Two ways it has happened
# here: a syntax error inside a `cond && ok || bad` list abandons the whole list so
# NEITHER branch runs, and assertions appended below this summary never execute at all
# (six did, once). shellcheck flags the idiom ~109 times across these suites and cannot
# tell a deliberate one from a broken one — this can.
#
# Raise EXPECTED_CHECKS deliberately when you add an assertion. That edit is the review
# trail, the same way the mutation-catalog floor works.
EXPECTED_CHECKS=45
if [ "$checks" -ne "$EXPECTED_CHECKS" ]; then
	echo "ran $checks checks, expected $EXPECTED_CHECKS — an assertion vanished, or one was added without raising EXPECTED_CHECKS"
	fails=$((fails + 1))
fi
[ "$fails" -eq 0 ] && echo "all checks passed ($checks checks)" || echo "$fails check(s) failed"
exit "$fails"
