#!/bin/bash
# Smallest thing that fails if the two-phase record or its guards break.
#   ./runlog.test.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 1
PY=$(command -v python3.14 || command -v python3)
# Must land in $TMPDIR: the sandbox refuses mkdtemp elsewhere, and an empty $TMP
# silently rewrites every store path to "/" — which turns half these checks into
# false passes on empty output.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-loop-test.XXXXXX") || { echo "mktemp failed"; exit 1; }
[ -d "$TMP" ] && [ -w "$TMP" ] || { echo "no writable temp dir at '$TMP'"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export REVIEW_LOOP_RUNS="$TMP/runs.jsonl"
fails=0
NL=$'\n'
TAB=$'\t'
ok() { echo "  ok  $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }

GATES='{"threat_model":{"planned":"run","reason":"2 stale claims"},"staleness_sweep":{"planned":"skip","reason":"12 entries"}}'

rid=$("$PY" runlog.py plan --tier full --model claude-opus-5 --gates "$GATES" --inputs '{"logic":true}')
[ -n "$rid" ] && ok "plan returns a run id" || { bad "plan returns a run id"; echo "  (setup failed, rest is meaningless)"; exit 1; }

"$PY" runlog.py check >/dev/null 2>&1
[ $? -eq 1 ] && ok "check flags an unfinished run" || bad "check flags an unfinished run"

# Capture first: `check` exits 1 by design when a run is open, and under pipefail
# that makes every `check | grep` pipeline report failure whatever grep found.
chk=$("$PY" runlog.py check 2>/dev/null)
grep -q threat_model <<<"$chk" \
	&& ok "check names the planned gate" || bad "check names the planned gate"
# Guard on non-empty: an inverted grep is satisfied by "the command printed
# nothing" exactly as well as by "the command correctly omitted it".
[ -n "$chk" ] && ! grep -q staleness_sweep <<<"$chk" \
	&& ok "check lists only planned-run gates" || bad "check lists only planned-run gates"

# The whole point: a precedent reason is refused, and refusing it writes nothing.
out=$("$PY" runlog.py finish --run-id "$rid" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"skipped","reason":"matches an existing pattern in the repo"}}' 2>&1)
if [ $? -ne 0 ] && grep -qi precedent <<<"$out"; then ok "precedent reason rejected"; else bad "precedent reason rejected"; fi
"$PY" runlog.py check >/dev/null 2>&1
[ $? -eq 1 ] && ok "rejected finish wrote nothing" || bad "rejected finish wrote nothing"

# A measurable reason goes through.
"$PY" runlog.py finish --run-id "$rid" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"done"}}' --asks 0 >/dev/null 2>&1 \
	&& ok "measurable finish accepted" || bad "measurable finish accepted"
"$PY" runlog.py check >/dev/null 2>&1
[ $? -eq 0 ] && ok "check clean after finish" || bad "check clean after finish"

"$PY" runlog.py show --run-id "$rid" | grep -q '"outcome": "clean"' \
	&& ok "phases merge on read" || bad "phases merge on read"

rid2=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
[ -n "$rid2" ] || { bad "second plan"; exit 1; }

# --head scopes check to one tip; without it the Stop hook could block on a run
# from a different branch, or miss the one it is actually standing in front of.
head=$(git rev-parse HEAD)
"$PY" runlog.py check --head "$head" >/dev/null 2>&1
[ $? -eq 1 ] || bad "check --head matches the planned tip"
"$PY" runlog.py check --head 0000000000000000000000000000000000000000 >/dev/null 2>&1
[ $? -eq 0 ] && ok "check --head ignores another tip's run" || bad "check --head ignores another tip's run"

# The precedent ban covers escalation reasons too, not just executed-gate ones.
out=$("$PY" runlog.py finish --run-id "$rid2" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"done"}}' \
	--escalations '[{"gate":"agent_7_structural","reason":"follows the existing pattern"}]' 2>&1)
if [ $? -ne 0 ] && grep -qi precedent <<<"$out"; then ok "precedent rejected in an escalation reason"; else bad "precedent rejected in an escalation reason"; fi


# A torn line must not invalidate the store.
printf '{"run_id":"broke' >> "$REVIEW_LOOP_RUNS"
"$PY" runlog.py show --run-id "$rid" >/dev/null 2>&1 \
	&& ok "torn line tolerated" || bad "torn line tolerated"

# A plan is the artifact everything else is derived from, so a malformed one must not
# enter the record. `planned_gates` demands an account only for "run", so a third value
# was dropped silently AND escaped the reason ban — the same stale-list shape as `n/a`.
for pv in deferred "" maybe; do
	# A MEASURABLE reason, deliberately: with a banned one, reject_banned does the
	# refusing and this assertion passes with the planned-value guard deleted. That is
	# how the first version of this check was hollow.
	out=$("$PY" runlog.py plan --tier full --model m \
		--gates "{\"threat_model\":{\"planned\":\"$pv\",\"reason\":\"2 stale claims, 40 changed lines\"}}" 2>&1)
	# Refused, and no row written: a bad plan leaves nothing behind to be finished.
	if ! grep -qE '^[0-9a-f]{12}$' <<<"$(tail -1 <<<"$out")"; then
		ok "a gate planned '$pv' is refused, not recorded"
	else
		bad "a gate planned '$pv' is refused, not recorded"
	fi
done
# The ban now applies to a planned skip's reason whatever the value is called.
out=$("$PY" runlog.py plan --tier full --model m \
	--gates '{"t":{"planned":"skip","reason":"matches an existing pattern"}}' 2>&1)
grep -qi precedent <<<"$out" && ok "a planned skip's reason is still vetted" || bad "a planned skip's reason is still vetted"
# An unexplained plan cannot be iterated on, which is the whole purpose of the record.
out=$("$PY" runlog.py plan --tier full --model m --gates '{"t":{"planned":"skip"}}' 2>&1)
grep -q 'no reason' <<<"$out" && ok "a gate with no reason is refused at plan time" || bad "a gate with no reason is refused at plan time"
# And the legitimate plan every real run writes still works.
rid=$("$PY" runlog.py plan --tier full --model m --gates '{"t":{"planned":"skip","reason":"12 entries, under the 40 threshold"}}' 2>&1 | tail -1)
[[ "$rid" =~ ^[0-9a-f]{12}$ ]] && ok "a well-formed plan still records" || bad "a well-formed plan still records (got: $rid)"

# --- cycle rows and derived convergence. The whole point: push-check used to be TOLD
# --- whether the loop converged, and a real run recorded `clean` while its own author
# --- reported it had not. Convergence must be a fact about recorded cycles.
export REVIEW_LOOP_RUNS="$TMP/cycles.jsonl"
cy() { "$PY" runlog.py cycle --run-id "$1" --n "$2" --applied "$3" --agents "$4" "${@:5}" >/dev/null 2>&1; }
conv() { "$PY" runlog.py convergence --run-id "$1" 2>/dev/null; }

# Cycle rows ACCUMULATE. load() merges phases with .update(), which would leave only the
# last cycle and destroy the sequence everything here is derived from.
r=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
cy "$r" 1 5 6; cy "$r" 2 3 3; cy "$r" 3 0 2
n=$("$PY" runlog.py show --run-id "$r" | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin).get("cycles") or []))')
[ "$n" = "3" ] && ok "three cycle rows survive as three" || bad "three cycle rows survive as three (got: $n)"
[ "$(conv "$r")" = "converged" ] && ok "a final zero-fix cycle derives converged" || bad "a final zero-fix cycle derives converged (got: $(conv "$r"))"
"$PY" runlog.py convergence --run-id "$r" >/dev/null 2>&1 && ok "and exits 0" || bad "and exits 0"

# Still applying fixes, budget left over: neither converged nor capped.
r=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
cy "$r" 1 5 6; cy "$r" 2 3 3
[ "$(conv "$r")" = "halted" ] && ok "fixes still landing with budget left derives halted" || bad "fixes still landing with budget left derives halted (got: $(conv "$r"))"

# Over the recorded agent cap with work outstanding.
r=$("$PY" runlog.py plan --tier full --model m --agent-cap 8 --gates "$GATES")
cy "$r" 1 5 6; cy "$r" 2 3 3
[ "$(conv "$r")" = "capped" ] && ok "over the agent cap with work outstanding derives capped" || bad "over the agent cap with work outstanding derives capped (got: $(conv "$r"))"

# Converged outranks capped: nothing left to apply is finished, however much it cost.
r=$("$PY" runlog.py plan --tier full --model m --agent-cap 8 --gates "$GATES")
cy "$r" 1 9 9; cy "$r" 2 0 1
[ "$(conv "$r")" = "converged" ] && ok "converged outranks capped" || bad "converged outranks capped (got: $(conv "$r"))"

# The deterministic pass still having work is as unfinished as a non-empty fix bucket.
r=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
cy "$r" 1 0 2 --analysis-changed
[ "$(conv "$r")" != "converged" ] && ok "analysis-changed blocks convergence at zero fixes" || bad "analysis-changed blocks convergence at zero fixes"

# NO cycle rows must read as not-converged, or omitting them buys a silent clean push.
r=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
[ "$(conv "$r")" = "unknown" ] && ok "no cycle rows reads as unknown, never converged" || bad "no cycle rows reads as unknown, never converged (got: $(conv "$r"))"
"$PY" runlog.py convergence --run-id "$r" >/dev/null 2>&1 && bad "unknown must not exit 0" || ok "and unknown does not exit 0"
# finish must SAY so, where it can still be fixed, rather than letting the gate refuse later.
out=$("$PY" runlog.py finish --run-id "$r" --outcome clean --tier full --executed '{"threat_model":{"status":"done"}}' 2>&1)
grep -q 'no cycle rows' <<<"$out" && ok "finish warns when convergence is unknowable" || bad "finish warns when convergence is unknowable"

# Every recorded cycle counts against the budget, including a repeated `n`. Step 13 and
# 13.5 restart the loop from cycle 1, so an `n` repeats on any run that restarts — and
# deduping by `n` made the restart's row REPLACE the original, deleting its agents from
# the only number the cap is measured against. Measured before the fix: 40 agents spent
# across three rows counted 20 against a cap of 40.
#
# The previous check here asserted "a re-recorded cycle supersedes, last write winning"
# by testing the raw row count (2 either way) and a convergence that read `converged`
# under both behaviours, so it discriminated nothing.
r=$("$PY" runlog.py plan --tier full --model m --gates "$GATES" --agent-cap 10)
cy "$r" 1 4 6; cy "$r" 2 2 3; cy "$r" 1 1 4   # restart repeats n=1; 13 agents of a 10 cap
n=$("$PY" runlog.py show --run-id "$r" | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin).get("cycles") or []))')
[ "$n" = "3" ] && ok "a restart's repeated cycle number is kept, not collapsed" \
	|| bad "a restart's repeated cycle number is kept, not collapsed (rows=$n)"
[ "$(conv "$r")" = "capped" ] && ok "and its agents count against the cap (13 of 10 = capped)" \
	|| bad "and its agents count against the cap (got: $(conv "$r"))"
"$PY" runlog.py show --run-id "$r" | "$PY" -c '
import json, sys
sys.path.insert(0, ".")
import runlog
run = json.load(sys.stdin)
spent = sum(c.get("agents") or 0 for c in runlog.cycles_of(run))
assert spent == 13, f"cycles_of dropped a row: {spent} agents, expected 13"
# The disclosure must quote the same spend as the derivation it explains: reading the raw
# list here while convergence() read the deduped one put "CAPPED at 11 of 8 agents" above
# a table showing 8.
assert "13 of 10" in runlog.disclosure("capped", run), runlog.disclosure("capped", run)
' && ok "and the disclosure quotes the same spend as the derivation" \
	|| bad "and the disclosure quotes the same spend as the derivation"

# An ask-bucket-only cycle has not run out of findings. It applied nothing, so the old
# test (`applied == 0`) read it as converged, which bought a push with no disclosure.
r=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
"$PY" runlog.py cycle --run-id "$r" --n 1 --applied 0 --asked 7 --agents 6 >/dev/null 2>&1
[ "$(conv "$r")" = "halted" ] && ok "a cycle that only asked has not converged" \
	|| bad "a cycle that only asked has not converged (got: $(conv "$r"))"
"$PY" -c '
import sys; sys.path.insert(0, ".")
import runlog
d = runlog.disclosure("halted", {"cycles": [{"n": 1, "applied": 0, "asked": 7, "agents": 6}]})
assert "7 finding(s) awaiting a decision" in d, d
' && ok "and the disclosure names the findings left undecided" \
	|| bad "and the disclosure names the findings left undecided"

# A cycle row appended after `finish` rewrites a convergence that has already been
# disclosed on a PR and already cleared a push — the assertion path the derivation
# replaced, respelled as `cycle --applied 0 --agents 0`.
r=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
cy "$r" 1 4 6
"$PY" runlog.py finish --run-id "$r" --outcome cycle-limit --tier full \
	--executed '{"threat_model":{"status":"done"}}' >/dev/null 2>&1
before=$(conv "$r")
out=$("$PY" runlog.py cycle --run-id "$r" --n 2 --applied 0 --agents 0 2>&1)
grep -q 'already finished' <<<"$out" && ok "a cycle row after finish is refused" \
	|| bad "a cycle row after finish is refused (got: $out)"
[ "$(conv "$r")" = "$before" ] && ok "and the reported convergence is unchanged ($before)" \
	|| bad "and the reported convergence is unchanged (was $before, now $(conv "$r"))"

# A negative count pulls cumulative spend back under a real cap. Needs its own run: on a
# finished one the post-finish guard fires first and the check passes for the wrong reason.
r=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
out=$("$PY" runlog.py cycle --run-id "$r" --n 3 --applied 1 --agents -100 2>&1)
grep -q 'cannot be negative' <<<"$out" && ok "a negative agent count is refused" \
	|| bad "a negative agent count is refused (got: $out)"

# A cap that cannot bind only changes which label a stall gets: zero makes `capped`
# unreachable, negative makes every unconverged run read `capped`.
for bad_cap in 0 -1; do
	out=$("$PY" runlog.py plan --tier full --model m --gates "$GATES" --agent-cap "$bad_cap" 2>&1)
	grep -q 'must be positive' <<<"$out" && ok "--agent-cap $bad_cap is refused" \
		|| bad "--agent-cap $bad_cap is refused (got: $out)"
done

# The derivation displaced the self-reported outcome; the self-report stayed. When they
# disagree, say so — run b480b45cc65d recorded `clean` for a run that did not converge.
r=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
cy "$r" 1 5 6
out=$("$PY" runlog.py finish --run-id "$r" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"done"}}' 2>&1)
grep -q "outcome 'clean' but the cycle rows derive" <<<"$out" \
	&& ok "finish names a self-report that contradicts the derivation" \
	|| bad "finish names a self-report that contradicts the derivation (got: $out)"

# The disclosure obligation is what a capped run pushes ON, so it has to be checkable.
r=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
cy "$r" 1 5 6
"$PY" runlog.py finish --run-id "$r" --outcome cycle-limit --tier full \
	--executed '{"threat_model":{"status":"done"}}' >/dev/null 2>&1
pend() { "$PY" -c '
import json, sys; sys.path.insert(0, ".")
import runlog
print(runlog.disclosure_pending(runlog.load(limit=None)["'"$1"'"], "'"$2"'") or "CLEAR")
'; }
[ "$(pend "$r" aaaa111)" != "CLEAR" ] && ok "an undisclosed non-converged run is not clear to push" \
	|| bad "an undisclosed non-converged run is not clear to push"
"$PY" runlog.py disclosed --run-id "$r" --where "pending file" --head aaaa111 >/dev/null 2>&1
[ "$(pend "$r" aaaa111)" = "CLEAR" ] && ok "and is clear once the disclosure is recorded" \
	|| bad "and is clear once the disclosure is recorded (got: $(pend "$r" aaaa111))"
[ "$(pend "$r" bbbb222)" != "CLEAR" ] && ok "but only for the commit it describes" \
	|| bad "but only for the commit it describes"

# The precedent ban matched raw text, so whitespace walked straight through it: a reason
# long enough to wrap carries a newline mid-phrase, which is the ordinary case rather than
# an evasion. Three of these five phrasings used to be recorded.
for variant in "matches  an   existing    pattern" "matches${NL}an existing pattern" \
	"matches an existing${TAB}pattern" "MATCHES AN EXISTING PATTERN" "matches an existing pattern"; do
	out=$("$PY" runlog.py skipped --reason "$variant" --model m 2>&1 | head -1)
	grep -q refusing <<<"$out" && ok "precedent refused through whitespace: $(printf '%s' "$variant" | tr '\n\t' '  ' | cut -c1-32)" \
		|| bad "precedent refused through whitespace: $(printf '%s' "$variant" | tr '\n\t' '  ' | cut -c1-32) (got: $out)"
done
# And a measurable reason still records.
out=$("$PY" runlog.py skipped --reason "12 lines and no logic touched" --model m 2>&1 | head -1)
grep -q refusing <<<"$out" && bad "a measurable reason still records" || ok "a measurable reason still records"

# A cycle for a run that was never planned is a row with nothing to attach to.
out=$("$PY" runlog.py cycle --run-id deadbeefdead --n 1 --applied 0 --agents 1 2>&1)
grep -q 'no plan' <<<"$out" && ok "a cycle without a plan is refused" || bad "a cycle without a plan is refused"
export REVIEW_LOOP_RUNS="$TMP/runs.jsonl"

# A malformed executed entry is not an account. `{"gate":"done"}` — the natural typo
# for `{"gate":{"status":"done"}}` — passed every isinstance guard and recorded `full`
# while review-stats.py read the same gate as dropped.
rid=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
out=$("$PY" runlog.py finish --run-id "$rid" --outcome clean --tier full \
	--executed '{"threat_model":"done"}' 2>&1)
shown=$("$PY" runlog.py show --run-id "$rid" 2>/dev/null)
if [ -n "$out" ] && ! grep -q '"tier_executed"' <<<"$shown"; then
	ok "a non-object executed entry is refused, and nothing is written"
else
	bad "a non-object executed entry is refused, and nothing is written"
fi

# `n/a` was the one status whose reason escaped the precedent ban: cmd_finish demanded
# a reason for it, nothing vetted that reason, and `n/a` also suppresses both the
# partial tier and the alarm — so the strongest claim in the vocabulary ("this gate
# cannot apply here") was the cheapest to make. The same reason must be refused under
# every status that owes one, not just the two that were listed.
for st in skipped failed "n/a"; do
	rid=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
	out=$("$PY" runlog.py finish --run-id "$rid" --outcome clean --tier full \
		--executed "{\"threat_model\":{\"status\":\"$st\",\"reason\":\"matches an existing pattern in the repo\"}}" 2>&1)
	# Refused BEFORE writing: a rejected reason must leave no finish row behind.
	shown=$("$PY" runlog.py show --run-id "$rid" 2>/dev/null)
	if grep -qi precedent <<<"$out" && ! grep -q '"tier_executed"' <<<"$shown"; then
		ok "a precedent reason is refused under status '$st', and nothing is written"
	else
		bad "a precedent reason is refused under status '$st', and nothing is written"
	fi
done
# The complement: a measurable n/a reason is exactly what the status is for.
rid=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
"$PY" runlog.py finish --run-id "$rid" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"n/a","reason":"no attacker-reachable surface in this repo"}}' >/dev/null 2>&1
"$PY" runlog.py show --run-id "$rid" | grep -q '"tier_executed": "full"' \
	&& ok "a measurable n/a reason records full" || bad "a measurable n/a reason records full"

# Alarm fires on the third non-completion, not the second.
export REVIEW_LOOP_RUNS="$TMP/alarm.jsonl"
for _ in 1 2; do
	r=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
	"$PY" runlog.py finish --run-id "$r" --outcome clean --tier full \
		--executed '{"threat_model":{"status":"skipped","reason":"gh unauthenticated"}}' >/dev/null
done
[ -z "$("$PY" review-stats.py --alarm)" ] && ok "alarm silent at 2" || bad "alarm silent at 2"
r=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
"$PY" runlog.py finish --run-id "$r" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"skipped","reason":"gh unauthenticated"}}' >/dev/null
"$PY" review-stats.py --alarm | grep -q "threat_model did not complete 3x" \
	&& ok "alarm fires at 3" || bad "alarm fires at 3"

# The ban guards every write path, not just finish — plan and abandon carry free
# text too, and both are directly invocable.
out=$("$PY" runlog.py plan --tier full --model m \
	--gates '{"agent_7_structural":{"planned":"skip","reason":"same pattern as the rest of the repo"}}' 2>&1)
if [ $? -ne 0 ] && grep -qi precedent <<<"$out"; then ok "precedent rejected on the plan path"; else bad "precedent rejected on the plan path"; fi

rida=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
out=$("$PY" runlog.py abandon --run-id "$rida" --missing "consistent with existing code" 2>&1)
if [ $? -ne 0 ] && grep -qi precedent <<<"$out"; then ok "precedent rejected on the abandon path"; else bad "precedent rejected on the abandon path"; fi

# A finish is terminal: abandoning afterwards must not half-overwrite it.
"$PY" runlog.py finish --run-id "$rida" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"done"}}' >/dev/null 2>&1
"$PY" runlog.py abandon --run-id "$rida" --missing "late abandon" >/dev/null 2>&1
[ $? -ne 0 ] && ok "abandon refuses an already-finished run" || bad "abandon refuses an already-finished run"
"$PY" runlog.py show --run-id "$rida" | grep -q '"outcome": "clean"' \
	&& ok "the finished outcome survived" || bad "the finished outcome survived"

# The roster invariant: a finish that ignores a planned gate is refused outright.
# Without this the record only ever says as much as the orchestrator chose to say.
rid3=$("$PY" runlog.py plan --tier full --model m \
	--gates '{"threat_model":{"planned":"run","reason":"2 stale"},"security_review":{"planned":"run","reason":"always"}}')
out=$("$PY" runlog.py finish --run-id "$rid3" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"done"}}' 2>&1)
if [ $? -ne 0 ] && grep -q security_review <<<"$out"; then ok "finish refuses an unaccounted planned gate"; else bad "finish refuses an unaccounted planned gate"; fi
"$PY" runlog.py check --run-id "$rid3" >/dev/null 2>&1
[ $? -eq 1 ] && ok "refused finish left the run open" || bad "refused finish left the run open"

# An escalation accounts for a gate just as an executed entry does.
"$PY" runlog.py finish --run-id "$rid3" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"done"}}' \
	--escalations '[{"gate":"security_review","reason":"ran it twice, diff touched auth"}]' >/dev/null 2>&1 \
	&& ok "an escalation accounts for a planned gate" || bad "an escalation accounts for a planned gate"

# partial is derived from what happened, not taken from the caller.
rid4=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
"$PY" runlog.py finish --run-id "$rid4" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"failed","reason":"agent timed out"}}' >/dev/null 2>&1
"$PY" runlog.py show --run-id "$rid4" | grep -q '"tier_executed": "partial"' \
	&& ok "a failed gate forces tier partial" || bad "a failed gate forces tier partial"

rid5=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
"$PY" runlog.py finish --run-id "$rid5" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"done"}}' \
	--agents '[{"id":"2-bugs","status":"failed"}]' >/dev/null 2>&1
"$PY" runlog.py show --run-id "$rid5" | grep -q '"tier_executed": "partial"' \
	&& ok "a failed agent forces tier partial" || bad "a failed agent forces tier partial"

# The other half, which nothing checked: a run where every agent SUCCEEDED must not
# be partial. Gates say `done`, so a caller writing the agent roster reaches for
# `done` too — and only `ok` was accepted, so five successful agents were counted as
# failures and the run recorded `partial`. Over-reporting partial is still a false
# record, and it teaches the next reader that partial is normal. Both words, because
# both are in use.
for word in ok "done"; do
	rid=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
	"$PY" runlog.py finish --run-id "$rid" --outcome clean --tier full \
		--executed '{"threat_model":{"status":"done"}}' \
		--agents "[{\"id\":\"2-bugs\",\"status\":\"$word\"}]" >/dev/null 2>&1
	shown=$("$PY" runlog.py show --run-id "$rid")
	grep -q '"tier_executed": "full"' <<<"$shown" \
		&& ok "an agent marked '$word' is a success, not a failure" \
		|| bad "an agent marked '$word' is a success, not a failure (got: $(grep tier_executed <<<"$shown"))"
done

# A deliberate skip is one complete row, not a second store to consult.
sk=$("$PY" runlog.py skipped --reason "docs-only, 4 lines, gitleaks clean")
"$PY" runlog.py show --run-id "$sk" | grep -q '"outcome": "skipped"' \
	&& ok "skipped writes one complete row" || bad "skipped writes one complete row"
"$PY" runlog.py check >/dev/null 2>&1
[ $? -eq 0 ] && ok "a skipped row leaves nothing open" || bad "a skipped row leaves nothing open"
out=$("$PY" runlog.py skipped --reason "matches an existing pattern in the repo" 2>&1)
if [ $? -ne 0 ] && grep -qi precedent <<<"$out"; then ok "precedent rejected on the skip path too"; else bad "precedent rejected on the skip path too"; fi

# A refused skip must write nothing. cmd_skipped appends twice, so a guard that
# only fires on the second write leaves the first behind as a phantom open run.
export REVIEW_LOOP_RUNS="$TMP/skipfail.jsonl"
"$PY" runlog.py skipped --reason "same pattern as the rest of the repo" >/dev/null 2>&1
[ ! -s "$REVIEW_LOOP_RUNS" ] && ok "a refused skip writes nothing at all" || bad "a refused skip writes nothing at all"
"$PY" runlog.py check >/dev/null 2>&1
[ $? -eq 0 ] && ok "a refused skip leaves no phantom open run" || bad "a refused skip leaves no phantom open run"

# The roster check must see the plan even after it scrolls past the read tail —
# a bounded read is right for "is anything open", wrong for "what did this plan".
export REVIEW_LOOP_RUNS="$TMP/tail.jsonl"
ridt=$(REVIEW_LOOP_TAIL=100 "$PY" runlog.py plan --tier full --model m \
	--gates '{"threat_model":{"planned":"run","reason":"2 stale"}}')
for _ in $(seq 20); do
	r=$(REVIEW_LOOP_TAIL=100 "$PY" runlog.py plan --tier full --model m --gates '{}')
	REVIEW_LOOP_TAIL=100 "$PY" runlog.py finish --run-id "$r" --outcome clean --tier full >/dev/null
done
out=$(REVIEW_LOOP_TAIL=2 "$PY" runlog.py finish --run-id "$ridt" --outcome clean --tier full \
	--executed '{}' 2>&1)
if [ $? -ne 0 ] && grep -q threat_model <<<"$out"; then ok "the roster check reads past the tail"; else bad "the roster check reads past the tail"; fi

# An execution-time skip of a gate the plan said to run IS an unexecuted gate,
# and it is the commonest way one actually gets dropped.
export REVIEW_LOOP_RUNS="$TMP/skiptier.jsonl"
rids=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
"$PY" runlog.py finish --run-id "$rids" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"skipped","reason":"no time this cycle"}}' >/dev/null 2>&1
"$PY" runlog.py show --run-id "$rids" | grep -q '"tier_executed": "partial"' \
	&& ok "a skipped planned gate forces tier partial" || bad "a skipped planned gate forces tier partial"

# A gate the PLAN already marked skip is not a failure if it turns up in
# executed — only gates the plan said to run can drag the tier down.
export REVIEW_LOOP_RUNS="$TMP/planskip.jsonl"
ridp=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
"$PY" runlog.py finish --run-id "$ridp" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"done"},"staleness_sweep":{"status":"skipped","reason":"12 entries"}}' >/dev/null 2>&1
"$PY" runlog.py show --run-id "$ridp" | grep -q '"tier_executed": "full"' \
	&& ok "a plan-level skip does not force partial" || bad "a plan-level skip does not force partial"

# Both report surfaces must agree what "abandoned" means: an explicitly
# abandoned run is abandoned, not "finished".
export REVIEW_LOOP_RUNS="$TMP/explicit.jsonl"
ride=$(CLAUDE_CODE_SESSION_ID=s1 "$PY" runlog.py plan --tier full --model m --gates '{}')
"$PY" runlog.py abandon --run-id "$ride" --missing "stopped for the day" >/dev/null
CLAUDE_CODE_SESSION_ID=s1 "$PY" review-stats.py | grep -q "finished: 0  abandoned: 1" \
	&& ok "an explicit abandon reports as abandoned, not finished" \
	|| bad "an explicit abandon reports as abandoned, not finished"

# An empty planned set means "the plan ran nothing", not "no plan information".
# Conflating them re-enabled the very behaviour the planned filter exists to stop.
export REVIEW_LOOP_RUNS="$TMP/emptyplan.jsonl"
ridz=$("$PY" runlog.py plan --tier full --model m \
	--gates '{"threat_model":{"planned":"skip","reason":"12 entries"}}')
"$PY" runlog.py finish --run-id "$ridz" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"skipped","reason":"the plan already skipped it"}}' >/dev/null 2>&1
"$PY" runlog.py show --run-id "$ridz" | grep -q '"tier_executed": "full"' \
	&& ok "an all-skipped plan does not force partial" || bad "an all-skipped plan does not force partial"

# A fat-fingered env override must not take down every invocation, including the
# Stop hook's per-turn check.
# Assert the exact code and the absence of a traceback: an uncaught exception
# also exits 1, so `-le 1` would pass on the very crash this guards against.
for badval in abc -5 "" "  "; do
	err=$(REVIEW_LOOP_TAIL="$badval" "$PY" runlog.py check 2>&1 >/dev/null)
	rc=$?
	[ "$rc" -eq 0 ] && ! grep -q Traceback <<<"$err" \
		&& ok "tail override '$badval' degrades, not crashes" \
		|| bad "tail override '$badval' degrades, not crashes (rc=$rc)"
done

# session_kind is one of the axes the record exists to answer, so a
# misclassification quietly corrupts that answer. The tty test alone called every
# interactive Claude Code run "headless", because its commands run with stdin detached.
export REVIEW_LOOP_RUNS="$TMP/kind.jsonl"
for pair in "1:interactive" "0:headless"; do
	val=${pair%%:*}; want=${pair##*:}
	rk=$(env -u AO_SESSION_ID CLAUDE_CODE_SESSION_ATTENDED="$val" "$PY" runlog.py plan --tier full --model m --gates '{}')
	"$PY" runlog.py show --run-id "$rk" | grep -q "\"session_kind\": \"$want\"" \
		&& ok "attended=$val records $want" || bad "attended=$val records $want"
done
rk=$(AO_SESSION_ID=abc CLAUDE_CODE_SESSION_ATTENDED=1 "$PY" runlog.py plan --tier full --model m --gates '{}')
"$PY" runlog.py show --run-id "$rk" | grep -q '"session_kind": "ao-worker"' \
	&& ok "an AO worker outranks the attended flag" || bad "an AO worker outranks the attended flag"

# `n/a` is not `skipped`: a gate with nothing to act on was not dropped, and a
# review of a repo that has no PRs and no telemetry is not a degraded review.
export REVIEW_LOOP_RUNS="$TMP/na.jsonl"
ridna=$("$PY" runlog.py plan --tier full --model m \
	--gates '{"pr_report":{"planned":"run","reason":"always"},"threat_model":{"planned":"run","reason":"2 stale"}}')
"$PY" runlog.py finish --run-id "$ridna" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"done"},"pr_report":{"status":"n/a","reason":"this repo has no PRs at all"}}' >/dev/null 2>&1
"$PY" runlog.py show --run-id "$ridna" | grep -q '"tier_executed": "full"' \
	&& ok "n/a does not force partial" || bad "n/a does not force partial"
# Capture, don't pipe: finish exits 1 by design here, and under pipefail that
# fails the pipeline whatever grep found.
ridna2=$("$PY" runlog.py plan --tier full --model m --gates '{"pr_report":{"planned":"run","reason":"always"}}')
naerr=$("$PY" runlog.py finish --run-id "$ridna2" --outcome clean --tier full \
	--executed '{"pr_report":{"status":"n/a"}}' 2>&1)
grep -q "no reason" <<<"$naerr" \
	&& ok "n/a still needs its reason" || bad "n/a still needs its reason"

# The floor is the whole point of "escalate, never descend" — and until now it was
# computed, recorded, and never checked.
export REVIEW_LOOP_RUNS="$TMP/floor.jsonl"
ridf=$("$PY" runlog.py plan --tier full --model m --gates '{}')
out=$("$PY" runlog.py finish --run-id "$ridf" --outcome clean --tier fast --executed '{}' 2>&1)
if [ $? -ne 0 ] && grep -q "floor" <<<"$out"; then ok "a tier below the plan's floor is refused"; else bad "a tier below the plan's floor is refused"; fi
"$PY" runlog.py finish --run-id "$ridf" --outcome clean --tier full --executed '{}' >/dev/null 2>&1 \
	&& ok "the floor itself is accepted" || bad "the floor itself is accepted"
ridg=$("$PY" runlog.py plan --tier fast --model m --gates '{}')
"$PY" runlog.py finish --run-id "$ridg" --outcome clean --tier full --executed '{}' >/dev/null 2>&1 \
	&& ok "escalating above the floor is allowed" || bad "escalating above the floor is allowed"

# A status without a reason answers "what happened" and not "why", which is the
# half anyone reading the record later actually needs.
export REVIEW_LOOP_RUNS="$TMP/noreason.jsonl"
ridn=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
out=$("$PY" runlog.py finish --run-id "$ridn" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"skipped"}}' 2>&1)
if [ $? -ne 0 ] && grep -q "no reason" <<<"$out"; then ok "a not-done gate with no reason is refused"; else bad "a not-done gate with no reason is refused"; fi

# A session that re-planned after an error leaves an earlier run open; reporting
# only the newest made it invisible for the rest of that session's life.
export REVIEW_LOOP_RUNS="$TMP/twoopen.jsonl"
r1=$(CLAUDE_CODE_SESSION_ID=s9 "$PY" runlog.py plan --tier full --model m --gates "$GATES")
r2=$(CLAUDE_CODE_SESSION_ID=s9 "$PY" runlog.py plan --tier full --model m --gates "$GATES")
chk2=$(CLAUDE_CODE_SESSION_ID=s9 "$PY" runlog.py check 2>/dev/null)
grep -q "$r1" <<<"$chk2" && grep -q "$r2" <<<"$chk2" \
	&& ok "check reports every open run, not just the newest" \
	|| bad "check reports every open run, not just the newest"

# A paraphrase is the realistic shape, since the writer is an LLM.
export REVIEW_LOOP_RUNS="$TMP/paraphrase.jsonl"
out=$("$PY" runlog.py skipped --reason "this is how the rest of the codebase does it" 2>&1)
if [ $? -ne 0 ] && grep -qi precedent <<<"$out"; then ok "a paraphrased precedent reason is refused"; else bad "a paraphrased precedent reason is refused"; fi
export REVIEW_LOOP_RUNS="$TMP/runs.jsonl"

# With no session env we cannot tell dead from in-flight, so we must not guess.
export REVIEW_LOOP_RUNS="$TMP/nosess.jsonl"
CLAUDE_CODE_SESSION_ID=live-elsewhere "$PY" runlog.py plan --tier full --model m --gates '{}' >/dev/null
noenv=$(env -u CLAUDE_CODE_SESSION_ID -u AO_SESSION_ID REVIEW_LOOP_RUNS="$TMP/nosess.jsonl" "$PY" review-stats.py)
grep -q "abandoned: 0" <<<"$noenv" \
	&& ok "no session env means no abandonment guess" || bad "no session env means no abandonment guess"
export REVIEW_LOOP_RUNS="$TMP/runs.jsonl"

# A concurrent worktree session's open run must not block this session's Stop.
export REVIEW_LOOP_RUNS="$TMP/sessions.jsonl"
CLAUDE_CODE_SESSION_ID=sess-a "$PY" runlog.py plan --tier full --model m --gates "$GATES" >/dev/null
CLAUDE_CODE_SESSION_ID=sess-b "$PY" runlog.py check >/dev/null 2>&1
[ $? -eq 0 ] && ok "another session's open run is not mine" || bad "another session's open run is not mine"
CLAUDE_CODE_SESSION_ID=sess-a "$PY" runlog.py check >/dev/null 2>&1
[ $? -eq 1 ] && ok "my own open run still blocks" || bad "my own open run still blocks"

# Stop hook: prompts once per run, then stays quiet — and never writes an outcome
# for a run that may still be in flight.
export REVIEW_LOOP_RUNS="$TMP/hook.jsonl"
rid=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
[ -n "$rid" ] || { bad "hook setup"; exit 1; }
hook_out=$(echo '{"stop_hook_active":false}' | REVIEW_LOOP_RUNS="$TMP/hook.jsonl" ./stop-hook.sh)
grep -q '"decision": *"block"' <<<"$hook_out" && ok "stop hook blocks the first time" || bad "stop hook blocks the first time"
grep -q "$rid" <<<"$hook_out" && ok "block names the run" || bad "block names the run"

# Stop fires every turn, so a mid-flight run must be prompted once and then left
# alone — and must NEVER be written off as abandoned while it is still running.
hook_out=$(echo '{"stop_hook_active":true}' | REVIEW_LOOP_RUNS="$TMP/hook.jsonl" ./stop-hook.sh)
[ -z "$hook_out" ] && ok "second stop does not block" || bad "second stop does not block"
shown=$("$PY" runlog.py show --run-id "$rid")
[ -n "$shown" ] && ! grep -q '"outcome"' <<<"$shown" \
	&& ok "second stop writes no outcome for a live run" \
	|| bad "second stop writes no outcome for a live run"
grep -q '"phase": "nudge"' <<<"$shown" \
	&& ok "run recorded as nudged" || bad "run recorded as nudged"

# Abandonment is derived, not written: another session's open run reads as lost.
CLAUDE_CODE_SESSION_ID=someone-else REVIEW_LOOP_RUNS="$TMP/hook.jsonl" "$PY" review-stats.py \
	| grep -q "abandoned: 1" && ok "open run from another session reads as abandoned" \
	|| bad "open run from another session reads as abandoned"

rep=$(REVIEW_LOOP_RUNS="$TMP/alarm.jsonl" "$PY" review-stats.py)
grep -q "gates planned but not completed:" <<<"$rep" \
	&& ok "report lists incomplete gates" || bad "report lists incomplete gates"
grep -q "threat_model" <<<"$rep" && ok "report names the gate" || bad "report names the gate"
grep -qE "by orchestrator model:" <<<"$rep" \
	&& ok "report breaks down by model" || bad "report breaks down by model"

# The most-executed path in production: an ordinary Stop with nothing pending.
# A regression that blocked here would block every session on the machine.
quiet=$(echo '{"stop_hook_active":false}' | REVIEW_LOOP_RUNS="$TMP/empty.jsonl" ./stop-hook.sh)
rc=$?
[ -z "$quiet" ] && [ "$rc" -eq 0 ] \
	&& ok "hook is silent when no run is open" || bad "hook is silent when no run is open"
# Silence alone doesn't prove the early exit ran — the slow path is silent too.
# It does prove it if nothing was spawned that would have created the store.
[ ! -e "$TMP/empty.jsonl" ] \
	&& ok "hook exits before touching the store" || bad "hook exits before touching the store"

# --head must actually scope: a run planned at a different tip is not this one.
export REVIEW_LOOP_RUNS="$TMP/headscope.jsonl"
"$PY" runlog.py plan --tier full --model m --head 1111111111111111111111111111111111111111 --gates "$GATES" >/dev/null
hs=$(echo '{"stop_hook_active":false}' | REVIEW_LOOP_RUNS="$TMP/headscope.jsonl" ./stop-hook.sh)
[ -z "$hs" ] && ok "hook ignores a run planned at another tip" || bad "hook ignores a run planned at another tip"

# --allow-unaccounted is the escape path: it records the gap rather than hiding it.
export REVIEW_LOOP_RUNS="$TMP/allow.jsonl"
rida2=$("$PY" runlog.py plan --tier full --model m \
	--gates '{"threat_model":{"planned":"run","reason":"2 stale"},"security_review":{"planned":"run","reason":"always"}}')
"$PY" runlog.py finish --run-id "$rida2" --outcome clean --tier full --allow-unaccounted \
	--executed '{"threat_model":{"status":"done"}}' >/dev/null 2>&1 \
	&& ok "--allow-unaccounted permits the finish" || bad "--allow-unaccounted permits the finish"
shown2=$("$PY" runlog.py show --run-id "$rida2")
grep -q '"tier_executed": "partial"' <<<"$shown2" \
	&& ok "--allow-unaccounted still marks the run partial" || bad "--allow-unaccounted still marks the run partial"
grep -q "unaccounted at finish" <<<"$shown2" \
	&& ok "the unaccounted gate is named in the record" || bad "the unaccounted gate is named in the record"
export REVIEW_LOOP_RUNS="$TMP/runs.jsonl"

# Outside a git work tree the hook has nothing to guard and must not error.
outside=$(cd "$TMP" && echo '{"stop_hook_active":false}' | "$OLDPWD/stop-hook.sh" 2>&1)
rc=$?
[ -z "$outside" ] && [ "$rc" -eq 0 ] \
	&& ok "hook is silent outside a git repo" || bad "hook is silent outside a git repo"

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit "$fails"
