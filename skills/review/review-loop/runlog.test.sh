#!/bin/bash
# Smallest thing that fails if the two-phase record or its guards break.
#   ./runlog.test.sh
set -uo pipefail
cd "$(dirname "$0")"
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
grep -q staleness_sweep <<<"$chk" \
	&& bad "check must not list a gate planned as skip" || ok "check lists only planned-run gates"

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

# A concurrent worktree session's open run must not block this session's Stop.
export REVIEW_LOOP_RUNS="$TMP/sessions.jsonl"
CLAUDE_CODE_SESSION_ID=sess-a "$PY" runlog.py plan --tier full --model m --gates "$GATES" >/dev/null
CLAUDE_CODE_SESSION_ID=sess-b "$PY" runlog.py check >/dev/null 2>&1
[ $? -eq 0 ] && ok "another session's open run is not mine" || bad "another session's open run is not mine"
CLAUDE_CODE_SESSION_ID=sess-a "$PY" runlog.py check >/dev/null 2>&1
[ $? -eq 1 ] && ok "my own open run still blocks" || bad "my own open run still blocks"

# Stop hook: blocks once, then records abandoned rather than trapping the session.
export REVIEW_LOOP_RUNS="$TMP/hook.jsonl"
rid=$("$PY" runlog.py plan --tier full --model m --gates "$GATES")
[ -n "$rid" ] || { bad "hook setup"; exit 1; }
hook_out=$(echo '{"stop_hook_active":false}' | REVIEW_LOOP_RUNS="$TMP/hook.jsonl" ./stop-hook.sh)
grep -q '"decision": *"block"' <<<"$hook_out" && ok "stop hook blocks the first time" || bad "stop hook blocks the first time"
grep -q "$rid" <<<"$hook_out" && ok "block names the run" || bad "block names the run"

hook_out=$(echo '{"stop_hook_active":true}' | REVIEW_LOOP_RUNS="$TMP/hook.jsonl" ./stop-hook.sh)
[ -z "$hook_out" ] && ok "second stop does not block" || bad "second stop does not block"
"$PY" runlog.py show --run-id "$rid" | grep -q '"outcome": "abandoned"' \
	&& ok "second stop records abandoned" || bad "second stop records abandoned"

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit "$fails"
