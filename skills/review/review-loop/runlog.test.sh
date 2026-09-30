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

# Alarm fires on the third non-completion, not the second.
export REVIEW_LOOP_RUNS="$TMP/alarm.jsonl"
for i in 1 2; do
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

# A deliberate skip is one complete row, not a second store to consult.
sk=$("$PY" runlog.py skipped --reason "docs-only, 4 lines, gitleaks clean")
"$PY" runlog.py show --run-id "$sk" | grep -q '"outcome": "skipped"' \
	&& ok "skipped writes one complete row" || bad "skipped writes one complete row"
"$PY" runlog.py check >/dev/null 2>&1
[ $? -eq 0 ] && ok "a skipped row leaves nothing open" || bad "a skipped row leaves nothing open"
out=$("$PY" runlog.py skipped --reason "matches an existing pattern in the repo" 2>&1)
if [ $? -ne 0 ] && grep -qi precedent <<<"$out"; then ok "precedent rejected on the skip path too"; else bad "precedent rejected on the skip path too"; fi

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

# Outside a git work tree the hook has nothing to guard and must not error.
outside=$(cd "$TMP" && echo '{"stop_hook_active":false}' | "$OLDPWD/stop-hook.sh" 2>&1)
rc=$?
[ -z "$outside" ] && [ "$rc" -eq 0 ] \
	&& ok "hook is silent outside a git repo" || bad "hook is silent outside a git repo"

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit "$fails"
