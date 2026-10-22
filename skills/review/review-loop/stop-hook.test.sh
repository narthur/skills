#!/bin/bash
# Smallest thing that fails if the Stop hook breaks, or if the rows `looper record` writes
# stop reaching the report, the push gate and the alarm the skill installs.
#   ./stop-hook.test.sh
#
# looper's own tests pin the record's behaviour — the rows, the refusals, the exit statuses
# in internal/record/testdata/oracle, the alarm in internal/stats/testdata/oracle — against
# hand-written rows and frozen goldens. What this directory owns is the Stop hook, and the
# seam between the real writer and the readers it feeds. Rows are written as JSONL by hand
# except in the looper block, which writes them through the real writer.
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
checks=0
ok() { echo "  ok  $1"; checks=$((checks + 1)); }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); checks=$((checks + 1)); }

GATES='{"threat_model":{"planned":"run","reason":"2 stale claims"},"staleness_sweep":{"planned":"skip","reason":"12 entries"}}'

# A plan row in the shape `looper record` writes it, trimmed to the fields the hook reads.
# $1 store, $2 run id.
prow() { printf '{"run_id":"%s","phase":"plan","planned_at":"%s","repo":"r","session_id":%s,"agent_cap":%s,"gates":%s}\n' \
	"$2" "${6:-2026-01-01T00:00:00}" "${5:-null}" "${3:-40}" "${4:-$GATES}" >> "$1"; }

# --- the Stop hook, where it does not need looper to answer.
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

# Outside a git work tree the hook has nothing to guard and must not error — nor nag about
# a missing looper, since no run can be open there. HOME has none, so a hook that resolved
# looper before asking git would speak here.
s="$TMP/nonempty.jsonl"; prow "$s" x1
nohome="$TMP/nolooper-home"; mkdir -p "$nohome"
outside=$(cd "$TMP" && echo '{"stop_hook_active":false}' | HOME="$nohome" REVIEW_LOOP_RUNS="$s" "$OLDPWD/stop-hook.sh" 2>&1)
rc=$?
[ -z "$outside" ] && [ "$rc" -eq 0 ] \
	&& ok "hook is silent outside a git repo" || bad "hook is silent outside a git repo"

# No looper: a run may be open and nothing can say whether. Exiting 0 silently there is
# indistinguishable from "nothing open", so the hook must say so, without blocking.
hook_out=$(echo '{"stop_hook_active":false}' | HOME="$nohome" REVIEW_LOOP_RUNS="$s" ./stop-hook.sh)
rc=$?
msg=$("$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); print("BLOCKS" if "decision" in d else d.get("systemMessage",""))' <<<"$hook_out" 2>/dev/null)
[ "$rc" -eq 0 ] && grep -q "looper is missing" <<<"$msg" && grep -q "go install" <<<"$msg" \
	&& ok "a missing looper is reported, not swallowed, and blocks nothing" \
	|| bad "a missing looper is reported, not swallowed, and blocks nothing (rc=$rc, got: $hook_out)"

# --- looper: the Stop hook driving the real writer, and the rows it writes read back by the
# --- report, the push gate and the alarm. looper's own tests use hand-written rows and
# --- frozen goldens, so a field renamed on the writer's side would break the push gate, the
# --- report or the alarm with both repos green. Runs where looper is on PATH (locally; CI's
# --- trust job) and says so where it is not, adding its checks to the expected count only
# --- when they ran. The scripts resolve looper as $HOME/.local/bin/looper, so it is linked
# --- into a fixture HOME rather than found on PATH.
looper_checks=0
if real_looper=$(command -v looper); then
	looper_checks=16
	lhome="$TMP/looper-home"; mkdir -p "$lhome/.local/bin" && ln -s "$real_looper" "$lhome/.local/bin/looper"
	L="$lhome/.local/bin/looper"

	# Stop hook: prompts once per run, then stays quiet — and never writes an outcome
	# for a run that may still be in flight.
	export REVIEW_LOOP_RUNS="$TMP/hook.jsonl"
	rid=$("$L" record plan --tier full --model m --gates "$GATES")
	hook_out=$(echo '{"stop_hook_active":false}' | HOME="$lhome" ./stop-hook.sh)
	grep -q '"decision": *"block"' <<<"$hook_out" && ok "stop hook blocks the first time" || bad "stop hook blocks the first time"
	grep -q "$rid" <<<"$hook_out" && ok "block names the run" || bad "block names the run"
	grep -q "looper record finish --run-id $rid" <<<"$hook_out" && grep -q "looper record abandon --run-id $rid" <<<"$hook_out" \
		&& ok "and its advice names the looper record commands" || bad "and its advice names the looper record commands"

	# Stop fires every turn, so a mid-flight run must be prompted once and then left
	# alone — and must NEVER be written off as abandoned while it is still running.
	hook_out=$(echo '{"stop_hook_active":true}' | HOME="$lhome" ./stop-hook.sh)
	[ -z "$hook_out" ] && ok "second stop does not block" || bad "second stop does not block"
	shown=$("$L" record show --run-id "$rid")
	[ -n "$shown" ] && ! grep -q '"outcome"' <<<"$shown" \
		&& ok "second stop writes no outcome for a live run" \
		|| bad "second stop writes no outcome for a live run"
	grep -q '"phase": "nudge"' <<<"$shown" \
		&& ok "run recorded as nudged" || bad "run recorded as nudged"

	# A nudge that cannot be written leaves the run un-nudged, so the block repeats; the hook
	# must say why rather than discard the error. A wrapper fails `record nudge` alone and hands
	# everything else to the real binary — not a read-only store, which root writes anyway.
	nhome="$TMP/nudge-fails-home"; mkdir -p "$nhome/.local/bin"
	printf '#!/bin/sh\n[ "$1 $2" = "record nudge" ] && { echo "nudge write refused" >&2; exit 1; }\nexec "%s" "$@"\n' "$real_looper" > "$nhome/.local/bin/looper"
	chmod +x "$nhome/.local/bin/looper"
	export REVIEW_LOOP_RUNS="$TMP/nudge-fails.jsonl"
	rid=$("$L" record plan --tier full --model m --gates "$GATES")
	hook_out=$(echo '{"stop_hook_active":false}' | HOME="$nhome" ./stop-hook.sh)
	"$PY" -I -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["decision"]=="block" and "will repeat" in d["systemMessage"] and "nudge write refused" in d["systemMessage"]' <<<"$hook_out" 2>/dev/null \
		&& ok "a failed nudge still blocks, and says the prompt will repeat" \
		|| bad "a failed nudge still blocks, and says the prompt will repeat (got: $hook_out)"

	# --head must actually scope: a run planned at a different tip is not this one.
	export REVIEW_LOOP_RUNS="$TMP/headscope.jsonl"
	"$L" record plan --tier full --model m --head 1111111111111111111111111111111111111111 --gates "$GATES" >/dev/null
	hs=$(echo '{"stop_hook_active":false}' | HOME="$lhome" ./stop-hook.sh)
	[ -z "$hs" ] && ok "hook ignores a run planned at another tip" || bad "hook ignores a run planned at another tip"

	# An unreadable store makes `check` exit 1 with nothing on stdout — the same status as an
	# open run. The hook used to discard check's stderr and exit 0 on anything it could not
	# parse, so a store it could not read looked exactly like one with nothing open.
	mkdir -p "$TMP/store-is-a-dir"; : > "$TMP/store-is-a-dir/x"
	hook_out=$(echo '{"stop_hook_active":false}' | HOME="$lhome" REVIEW_LOOP_RUNS="$TMP/store-is-a-dir" ./stop-hook.sh)
	rc=$?
	msg=$("$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); print("BLOCKS" if "decision" in d else d.get("systemMessage",""))' <<<"$hook_out" 2>/dev/null)
	[ "$rc" -eq 0 ] && grep -q "cannot read the run store" <<<"$msg" \
		&& ok "an unreadable store is reported, not swallowed, and blocks nothing" \
		|| bad "an unreadable store is reported, not swallowed, and blocks nothing (rc=$rc, got: $hook_out)"

	# Rows looper wrote, read back by the report and the push gate the skill installs.
	export REVIEW_LOOP_RUNS="$TMP/looper.jsonl"
	lrid=$("$L" record plan --tier full --model claude-opus-5 --agent-cap 8 --gates '{}' --inputs '{"logic":true}')
	"$L" record cycle --run-id "$lrid" --n 1 --applied 3 --agents 5 >/dev/null 2>&1
	"$L" record cycle --run-id "$lrid" --n 2 --applied 1 --agents 4 >/dev/null 2>&1

	body=$("$L" pr-report --run-id "$lrid" </dev/null 2>&1)
	grep -q "2 cycle(s) · 9 agent(s)" <<<"$body" \
		&& ok "looper pr-report reads the recorded cycle rows" || bad "looper pr-report reads the recorded cycle rows: $body"
	grep -q "CAPPED" <<<"$body" \
		&& ok "looper pr-report derives capped from the agent cap" || bad "looper pr-report derives capped from the agent cap"
	pc=$("$L" push-check --run-id "$lrid" --branch feat/x --default-branch main 2>/dev/null)
	grep -q '"convergence":"capped"' <<<"$pc" \
		&& ok "looper push-check reads the same convergence" || bad "looper push-check reads the same convergence: $pc"
	# Step 14 closes the record before it posts the report, so a run with no finish row skipped
	# a step; the gate refuses it ahead of the report check and names the way out.
	grep -q '"push":false' <<<"$pc" && grep -q 'never finished' <<<"$pc" && grep -q "looper record finish --run-id $lrid" <<<"$pc" \
		&& ok "looper push-check refuses a run that was never finished" || bad "looper push-check refuses a run that was never finished: $pc"
	"$L" record finish --run-id "$lrid" --outcome cycle-limit --tier full >/dev/null 2>&1
	pc=$("$L" push-check --run-id "$lrid" --branch feat/x --default-branch main 2>/dev/null)
	pcrc=$?
	grep -q '"push":false' <<<"$pc" && grep -q 'report has not reached' <<<"$pc" \
		&& ok "looper push-check refuses a run whose report has not landed" || bad "looper push-check refuses a run whose report has not landed: $pc"
	# SKILL.md Step 14 says a refusal exits 3 with its JSON still on stdout, so a command
	# chained on push-check with && runs only on an allowed push. Before v0.2.10 a refusal
	# exited 0, so such a chain would push on push:false.
	[ "$pcrc" -eq 3 ] && grep -q '"reason"' <<<"$pc" \
		&& ok "looper push-check exits 3 on a refusal and still prints its reason" \
		|| bad "looper push-check exits 3 on a refusal and still prints its reason (exit $pcrc: $pc)"

	# And the alarm over finishes looper wrote: the third skip of one gate fires it. looper
	# stats' goldens are hand-written rows, so this is where the writer's rows reach it.
	export REVIEW_LOOP_RUNS="$TMP/looper-alarm.jsonl"
	for _ in 1 2 3; do
		r=$("$L" record plan --tier full --model m --gates "$GATES")
		"$L" record finish --run-id "$r" --outcome clean --tier full \
			--executed '{"threat_model":{"status":"skipped","reason":"gh unauthenticated"}}' >/dev/null 2>&1
	done
	"$L" stats --alarm | grep -q "threat_model was declined with a reason (skipped) 3x" \
		&& ok "the alarm reads looper's finish rows" || bad "the alarm reads looper's finish rows"
	export REVIEW_LOOP_RUNS="$TMP/runs.jsonl"
else
	echo "  skip  looper not on PATH — the looper checks did not run"
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
