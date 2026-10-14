#!/bin/bash
# Smallest thing that fails if the record's reader, its vocabulary, or the Stop hook breaks.
#   ./runlog.test.sh
#
# runlog.py's command line is `looper record` now, and its behaviour — the rows, the
# refusals, the exit statuses — is pinned by the 37 scenarios frozen in looper's
# internal/record/testdata/oracle, and the alarm and report review-stats.py drew from these
# rows are `looper stats`, pinned by the 61 stores frozen in internal/stats/testdata/oracle.
# What is left here is what this directory still owns: the library the Python scripts and
# looper's parity tests import (load, cycles_of, convergence, reject_banned) and the Stop
# hook. Rows are written as JSONL by hand except in the looper block at the end, which
# writes them through the real writer.
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
NL=$'\n'
TAB=$'	'
ok() { echo "  ok  $1"; checks=$((checks + 1)); }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); checks=$((checks + 1)); }

GATES='{"threat_model":{"planned":"run","reason":"2 stale claims"},"staleness_sweep":{"planned":"skip","reason":"12 entries"}}'

# Rows in the shape `looper record` writes them, trimmed to the fields the readers use.
# $1 store, $2 run id, then the fields that vary.
prow() { printf '{"run_id":"%s","phase":"plan","planned_at":"%s","repo":"r","session_id":%s,"agent_cap":%s,"gates":%s}\n' \
	"$2" "${6:-2026-01-01T00:00:00}" "${5:-null}" "${3:-40}" "${4:-$GATES}" >> "$1"; }
crow() { printf '{"run_id":"%s","phase":"cycle","n":%s,"applied":%s,"agents":%s,"asked":%s,"analysis_changed":%s}\n' \
	"$2" "$3" "$4" "$5" "${6:-0}" "${7:-false}" >> "$1"; }
EMPTY='{}'  # not "${5:-{\}}": bash 3.2, macOS's /bin/bash, keeps the backslash
frow() { printf '{"run_id":"%s","phase":"finish","finished_at":"2026-01-01T01:00:00","outcome":"%s","unresolved_asks":%s,"executed":%s}\n' \
	"$2" "$3" "${4:-0}" "${5:-$EMPTY}" >> "$1"; }
# The library under test, imported the way learn.py imports it.
lib() { REVIEW_LOOP_RUNS="$1" "$PY" -c "import sys; sys.path.insert(0, '.'); import runlog; $2"; }
conv() { lib "$1" "r = runlog.load(limit=None).get('$2'); print('NO-RUN' if r is None else (runlog.convergence(r) or 'unknown'))"; }

# --- the command line is gone, and says where it went rather than failing obscurely.
out=$("$PY" runlog.py plan --tier full --model m 2>&1)
rc=$?
[ "$rc" -eq 2 ] && ok "runlog.py as a command exits 2" || bad "runlog.py as a command exits 2 (got $rc)"
grep -q "looper record" <<<"$out" && [ "$(wc -l <<<"$out")" -eq 1 ] \
	&& ok "and says in one line that the command line is looper record" \
	|| bad "and says in one line that the command line is looper record (got: $out)"

# A torn line must not invalidate the store.
s="$TMP/torn.jsonl"
prow "$s" t1
printf '{"run_id":"broke' >> "$s"
[ "$(lib "$s" "print(sorted(runlog.load(limit=None)))")" = "['t1']" ] \
	&& ok "torn line tolerated" || bad "torn line tolerated"

# --- cycle rows and derived convergence. The whole point: push-check used to be TOLD
# --- whether the loop converged, and a real run recorded `clean` while its own author
# --- reported it had not. Convergence must be a fact about recorded cycles.
s="$TMP/cycles.jsonl"

# Cycle rows ACCUMULATE. load() merges phases with .update(), which would leave only the
# last cycle and destroy the sequence everything here is derived from.
prow "$s" c1; crow "$s" c1 1 5 6; crow "$s" c1 2 3 3; crow "$s" c1 3 0 2
n=$(lib "$s" "print(len(runlog.load(limit=None)['c1'].get('cycles') or []))")
[ "$n" = "3" ] && ok "three cycle rows survive as three" || bad "three cycle rows survive as three (got: $n)"
[ "$(conv "$s" c1)" = "converged" ] && ok "a final zero-fix cycle derives converged" || bad "a final zero-fix cycle derives converged (got: $(conv "$s" c1))"

# Still applying fixes, budget left over: neither converged nor capped.
prow "$s" c2; crow "$s" c2 1 5 6; crow "$s" c2 2 3 3
[ "$(conv "$s" c2)" = "halted" ] && ok "fixes still landing with budget left derives halted" || bad "fixes still landing with budget left derives halted (got: $(conv "$s" c2))"

# Over the recorded agent cap with work outstanding.
prow "$s" c3 8; crow "$s" c3 1 5 6; crow "$s" c3 2 3 3
[ "$(conv "$s" c3)" = "capped" ] && ok "over the agent cap with work outstanding derives capped" || bad "over the agent cap with work outstanding derives capped (got: $(conv "$s" c3))"

# Converged outranks capped: nothing left to apply is finished, however much it cost.
prow "$s" c4 8; crow "$s" c4 1 9 9; crow "$s" c4 2 0 1
[ "$(conv "$s" c4)" = "converged" ] && ok "converged outranks capped" || bad "converged outranks capped (got: $(conv "$s" c4))"

# The deterministic pass still having work is as unfinished as a non-empty fix bucket.
prow "$s" c5; crow "$s" c5 1 0 2 0 true
[ "$(conv "$s" c5)" != "converged" ] && ok "analysis-changed blocks convergence at zero fixes" || bad "analysis-changed blocks convergence at zero fixes"

# NO cycle rows must read as not-converged, or omitting them buys a silent clean push.
prow "$s" c6
[ "$(conv "$s" c6)" = "unknown" ] && ok "no cycle rows reads as unknown, never converged" || bad "no cycle rows reads as unknown, never converged (got: $(conv "$s" c6))"

# Every recorded cycle counts against the budget, including a repeated `n`. Step 13 and
# 13.5 restart the loop from cycle 1, so an `n` repeats on any run that restarts — and
# deduping by `n` made the restart's row REPLACE the original, deleting its agents from
# the only number the cap is measured against. Measured before the fix: 40 agents spent
# across three rows counted 20 against a cap of 40.
prow "$s" c7 10; crow "$s" c7 1 4 6; crow "$s" c7 2 2 3; crow "$s" c7 1 1 4   # restart repeats n=1; 13 agents of a 10 cap
# Counted through cycles_of, the reader under test — not the raw stored list, which holds
# 3 whether or not the read path collapses them.
n=$(lib "$s" "print(len(runlog.cycles_of(runlog.load(limit=None)['c7'])))")
[ "$n" = "3" ] && ok "a restart's repeated cycle number is kept, not collapsed" \
	|| bad "a restart's repeated cycle number is kept, not collapsed (cycles_of returned $n of 3)"
[ "$(conv "$s" c7)" = "capped" ] && ok "and its agents count against the cap (13 of 10 = capped)" \
	|| bad "and its agents count against the cap (got: $(conv "$s" c7))"

# An ask-bucket-only cycle has not run out of findings. It applied nothing, so the old
# test (`applied == 0`) read it as converged, which bought a push with no disclosure.
prow "$s" c8; crow "$s" c8 1 0 6 7
[ "$(conv "$s" c8)" = "halted" ] && ok "a cycle that only asked has not converged" \
	|| bad "a cycle that only asked has not converged (got: $(conv "$s" c8))"

# Asks recorded at finish are outstanding work even when no cycle row carries them. The
# omission path — `cycle --applied 0` with no --asked, then `finish --asks 7` — derived
# converged with no disclosure while seven findings sat unresolved with the user.
prow "$s" c9; crow "$s" c9 1 0 6; frow "$s" c9 clean 7
[ "$(conv "$s" c9)" = "halted" ] && ok "asks recorded at finish prevent converged" \
	|| bad "asks recorded at finish prevent converged (got: $(conv "$s" c9))"
# And a genuinely clean run still converges.
prow "$s" c10; crow "$s" c10 1 0 6; frow "$s" c10 clean 0
[ "$(conv "$s" c10)" = "converged" ] && ok "and zero asks still converges" \
	|| bad "and zero asks still converges (got: $(conv "$s" c10))"

# The precedent ban matched raw text, so whitespace walked straight through it: a reason
# long enough to wrap carries a newline mid-phrase, which is the ordinary case rather than
# an evasion. Three of these five phrasings used to be recorded. learn.py vets dismissals
# through this function; `looper record` carries its own copy of the list, held equal to
# BANNED_REASON by looper's TestWriteConstantsMatchThePython.
banned() { "$PY" -c 'import sys; sys.path.insert(0, "."); import runlog; runlog.reject_banned([("this skip", sys.argv[1])])' "$1" 2>&1; }
for variant in "matches  an   existing    pattern" "matches${NL}an existing pattern" \
	"matches an existing${TAB}pattern" "MATCHES AN EXISTING PATTERN" "matches an existing pattern"; do
	out=$(banned "$variant" | head -1)
	grep -q refusing <<<"$out" && ok "precedent refused through whitespace: $(printf '%s' "$variant" | tr '\n	' '  ' | cut -c1-32)" \
		|| bad "precedent refused through whitespace: $(printf '%s' "$variant" | tr '\n	' '  ' | cut -c1-32) (got: $out)"
done
# And a measurable reason still passes.
out=$(banned "12 lines and no logic touched")
[ -z "$out" ] && ok "a measurable reason still passes" || bad "a measurable reason still passes (got: $out)"
# A paraphrase is the realistic shape, since the writer is an LLM.
grep -q refusing <<<"$(banned "this is how the rest of the codebase does it")" \
	&& ok "a paraphrased precedent reason is refused" || bad "a paraphrased precedent reason is refused"

# A fat-fingered env override must not take down every importer. runlog.py parses
# REVIEW_LOOP_TAIL at import, and learn.py imports it, so a crash there would take the
# learnings capture down with it. Assert the exact code and the absence of a traceback:
# an uncaught exception also exits 1, so `-le 1` would pass on the very crash this guards against.
for badval in abc -5 "" "  "; do
	err=$(REVIEW_LOOP_TAIL="$badval" "$PY" -c 'import runlog' 2>&1 >/dev/null)
	rc=$?
	[ "$rc" -eq 0 ] && ! grep -q Traceback <<<"$err" \
		&& ok "tail override '$badval' degrades, not crashes" \
		|| bad "tail override '$badval' degrades, not crashes (rc=$rc)"
done

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

# --- looper: the Stop hook driving the real writer, and the record as looper and the
# --- Python readers each read rows the other wrote. looper's own tests use hand-written rows
# --- and frozen goldens, so a field renamed on either side would break the push gate, the
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

	# Rows looper wrote, read by the Python library looper's parity tests take as the oracle.
	export REVIEW_LOOP_RUNS="$TMP/looper.jsonl"
	lrid=$("$L" record plan --tier full --model claude-opus-5 --agent-cap 8 --gates '{}' --inputs '{"logic":true}')
	"$L" record cycle --run-id "$lrid" --n 1 --applied 3 --agents 5 >/dev/null 2>&1
	"$L" record cycle --run-id "$lrid" --n 2 --applied 1 --agents 4 >/dev/null 2>&1
	[ "$(lib "$REVIEW_LOOP_RUNS" "print(len(runlog.cycles_of(runlog.load(limit=None)['$lrid'])))")" = "2" ] \
		&& ok "runlog reads looper's cycle rows" || bad "runlog reads looper's cycle rows"
	lc=$("$L" record convergence --run-id "$lrid" 2>/dev/null)
	[ "$(conv "$REVIEW_LOOP_RUNS" "$lrid")" = "capped" ] && [ "$lc" = "capped" ] \
		&& ok "and derives the convergence looper does" || bad "and derives the convergence looper does (python $(conv "$REVIEW_LOOP_RUNS" "$lrid"), looper $lc)"

	# The same rows through the report and the push gate the skill installs.
	body=$("$L" pr-report --run-id "$lrid" </dev/null 2>&1)
	grep -q "2 cycle(s) · 9 agent(s)" <<<"$body" \
		&& ok "looper pr-report reads the recorded cycle rows" || bad "looper pr-report reads the recorded cycle rows: $body"
	grep -q "CAPPED" <<<"$body" \
		&& ok "looper pr-report derives capped from the agent cap" || bad "looper pr-report derives capped from the agent cap"
	pc=$("$L" push-check --run-id "$lrid" --branch feat/x --default-branch main 2>/dev/null)
	grep -q '"convergence":"capped"' <<<"$pc" \
		&& ok "looper push-check reads the same convergence" || bad "looper push-check reads the same convergence: $pc"
	grep -q '"push":false' <<<"$pc" && grep -q 'report has not reached' <<<"$pc" \
		&& ok "looper push-check refuses a run whose report has not landed" || bad "looper push-check refuses a run whose report has not landed: $pc"

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
EXPECTED_CHECKS=30
if [ "$checks" -ne $((EXPECTED_CHECKS + looper_checks)) ]; then
	echo "ran $checks checks, expected $((EXPECTED_CHECKS + looper_checks)) — an assertion vanished, or one was added without raising EXPECTED_CHECKS"
	fails=$((fails + 1))
fi
[ "$fails" -eq 0 ] && echo "all checks passed ($checks checks)" || echo "$fails check(s) failed"
exit "$fails"
