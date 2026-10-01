#!/bin/bash
# plan.py decides how much review a change gets, and its failure mode is silent
# under-review — the exact bug class the run record exists to prevent. --dry-run
# keeps this off the shared store, so every gate below is a pure function of the
# inputs and fully assertable.
#   ./plan.test.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 1
PY=$(command -v python3.14 || command -v python3)
fails=0
ok() { echo "  ok  $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }

# $1 changed_lines, $2 fast_eligible, $3.. plan.py flags -> plan JSON
plan() {
	local lines=$1 fast=$2; shift 2
	printf '{"changed_lines":%s,"fast_path_eligible_by_size":%s,"base_branch":"","learnings_entries":0,"learnings_compaction_due":false}' "$lines" "$fast" \
		| "$PY" plan.py --model test --dry-run "$@" 2>/dev/null
}
# gate planned value out of a plan JSON
gate() { "$PY" -c 'import json,sys; print(json.load(sys.stdin)["gates"][sys.argv[1]]["planned"])' "$1"; }
tier() { "$PY" -c 'import json,sys; print(json.load(sys.stdin)["tier_floor"])'; }

BOOLS_OFF="--logic no --behavioral-goal no --runtime-change no --attacker-reachable no"

# --- tier floor: fast needs BOTH under-size AND no logic. Flip either and it must not.
[ "$(plan 10 true $BOOLS_OFF | tier)" = "fast" ] && ok "small + no logic -> fast" || bad "small + no logic -> fast"
[ "$(plan 10 true --logic yes --behavioral-goal no --runtime-change no --attacker-reachable no | tier)" = "full" ] \
	&& ok "logic alone forces full" || bad "logic alone forces full"
[ "$(plan 900 false $BOOLS_OFF | tier)" = "full" ] && ok "size alone forces full" || bad "size alone forces full"

# The agent never names a tier, so there must be no flag that lowers it.
"$PY" plan.py --help 2>&1 | grep -qiE '\-\-tier|\-\-fast' \
	&& bad "no flag may let the caller pick a tier" || ok "no flag lets the caller pick a tier"

# --- fast path runs no conditional agents and folds the security finder in
p=$(plan 10 true $BOOLS_OFF)
# Count, then assert on the count — an unconditional ok after the loop reports
# success whatever the loop found.
skipped=0
for g in agent_7_structural agent_8_observability agent_9_intent agent_10_prior_feedback agent_11_spec; do
	[ "$(gate $g <<<"$p")" = "skip" ] && skipped=$((skipped + 1)) || bad "fast path skips $g"
done
[ "$skipped" -eq 5 ] && ok "fast path skips all 5 conditional agents" || bad "fast path skips all 5 conditional agents"
[ "$(gate security_review <<<"$p")" = "skip" ] && ok "fast path folds in the security finder" || bad "fast path folds in the security finder"

# --- semantic sizing drives the thresholds, not the raw count. A 900-line lockfile
# --- regeneration with a 10-line real edit must be sized as 10, or every dependency
# --- bump drags a 6-agent fan-out over a file nobody reads.
sem() {
	local raw=$1 semantic=$2 fast=$3; shift 3
	printf '{"changed_lines":%s,"semantic_lines":%s,"sizing_excluded":"890 line(s) in lockfiles or generated files","fast_path_eligible_by_size":%s,"base_branch":"","learnings_entries":0,"learnings_compaction_due":false}' \
		"$raw" "$semantic" "$fast" | "$PY" plan.py --model test --dry-run "$@" 2>/dev/null
}
p=$(sem 900 10 true $BOOLS_OFF)
[ "$(gate agent_7_structural <<<"$p")" = "skip" ] && ok "a 900-raw/10-semantic diff is under the structural floor" 	|| bad "a 900-raw/10-semantic diff is under the structural floor"
[ "$(tier <<<"$p")" = "fast" ] && ok "and is fast-path eligible on the semantic count" || bad "and is fast-path eligible on the semantic count"
# The tier reason must carry BOTH numbers and what was dropped — a smaller count that
# buys a cheaper review is exactly the decision that must not go unexplained. (On the
# fast path the gate reasons say "fast path runs no conditional agents"; the sizing
# explanation lives on the tier.)
tr=$("$PY" -c 'import json,sys; print(json.load(sys.stdin)["tier_reason"])' <<<"$p")
if grep -q 'review surface' <<<"$tr" && grep -q '900 raw' <<<"$tr" && grep -q 'excluded' <<<"$tr"; then
	ok "the tier reason gives semantic, raw, and what was excluded"
else
	bad "the tier reason gives semantic, raw, and what was excluded (got: $tr)"
fi
# Both counts reach the record, so a later reader can audit the sizing call itself.
"$PY" -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d["changed_lines"]==900 and d["semantic_lines"]==10 else 1)' <<<"$p" && ok "the plan records raw and semantic separately" || bad "the plan records raw and semantic separately"
# The inverse: raw small but semantic large cannot happen, but semantic must still be
# what forces full — a 900-semantic diff is full regardless of what raw says.
p=$(sem 900 900 false $BOOLS_OFF)
[ "$(gate agent_7_structural <<<"$p")" = "run" ] && ok "a 900-semantic diff runs #7" || bad "a 900-semantic diff runs #7"
# The pair above is NOT enough on its own: with fast_path_eligible_by_size true, #7 is
# skipped because the fast path runs no conditional agents, so those checks pass even if
# plan.py ignores semantic_lines entirely. This is the discriminating case — fast path
# OFF (logic touched), raw over the 150 floor, semantic under it. Only a plan that sizes
# on semantic_lines skips #7 here.
p=$(sem 900 10 false --logic yes --behavioral-goal no --runtime-change no --attacker-reachable no)
[ "$(gate agent_7_structural <<<"$p")" = "skip" ] && ok "off the fast path, #7 is gated on semantic lines not raw" \
	|| bad "off the fast path, #7 is gated on semantic lines not raw"
[ "$(gate agent_8_observability <<<"$p")" = "skip" ] && ok "and #8 follows it" || bad "and #8 follows it"
# Fallback: a context.sh predating semantic sizing has no semantic_lines field, and the
# plan must then size on raw rather than treating a missing field as zero.
p=$(plan 900 false $BOOLS_OFF)
[ "$(gate agent_7_structural <<<"$p")" = "run" ] && ok "no semantic_lines field falls back to raw" || bad "no semantic_lines field falls back to raw"
[ "$(tier <<<"$p")" = "full" ] && ok "and the fallback still forces full" || bad "and the fallback still forces full"

# --- #7/#8 substantial threshold, both sides of the boundary
p=$(plan 149 false $BOOLS_OFF)
[ "$(gate agent_7_structural <<<"$p")" = "skip" ] && ok "149 lines is under the structural floor" || bad "149 lines is under the structural floor"
p=$(plan 150 false $BOOLS_OFF)
[ "$(gate agent_7_structural <<<"$p")" = "run" ] && ok "150 lines is at the structural floor" || bad "150 lines is at the structural floor"
[ "$(gate agent_8_observability <<<"$p")" = "run" ] && ok "#8 follows #7's threshold" || bad "#8 follows #7's threshold"

# --- the judgment booleans gate exactly what they claim to
p=$(plan 900 false --logic yes --behavioral-goal yes --runtime-change no --attacker-reachable no)
[ "$(gate agent_9_intent <<<"$p")" = "run" ] && ok "behavioral goal gates #9 on" || bad "behavioral goal gates #9 on"
[ "$(gate evidence_gate <<<"$p")" = "skip" ] && ok "no runtime change skips the evidence gate" || bad "no runtime change skips the evidence gate"
p=$(plan 900 false --logic yes --behavioral-goal no --runtime-change yes --attacker-reachable no)
[ "$(gate agent_9_intent <<<"$p")" = "skip" ] && ok "no behavioral goal skips #9" || bad "no behavioral goal skips #9"
# The evidence gate needs somewhere to put the evidence, so it needs BOTH a
# runtime change and a PR. This repo has no PRs, so here it must skip — and say
# why, since "no PR" is deferral rather than a judgement that evidence is unneeded.
ev=$("$PY" -c 'import json,sys; g=json.load(sys.stdin)["gates"]["evidence_gate"]; print(g["planned"], "|", g["reason"])' <<<"$p")
case "$ev" in
	"skip | no PR to attach"*) ok "no PR defers the evidence gate, with the reason" ;;
	"run | "*) ok "a PR plus a runtime change runs the evidence gate" ;;
	*) bad "evidence gate reason explains itself (got: $ev)" ;;
esac
[ "$(gate measurement_gate <<<"$p")" = "run" ] && ok "runtime change runs the measurement gate" || bad "runtime change runs the measurement gate"
[ "$(gate agent_11_spec <<<"$p")" = "skip" ] && ok "no spec artifact skips #11" || bad "no spec artifact skips #11"
p=$(plan 900 false --logic yes --behavioral-goal no --runtime-change yes --attacker-reachable no --spec-artifact yes)
[ "$(gate agent_11_spec <<<"$p")" = "run" ] && ok "spec artifact runs #11" || bad "spec artifact runs #11"

# --- every gate carries a reason; an unexplained skip is the thing this prevents
"$PY" -c '
import json,sys
gates = json.load(sys.stdin)["gates"]
missing = [g for g, v in gates.items() if not (v.get("reason") or "").strip()]
sys.exit(1 if missing else 0)
' <<<"$p" && ok "every gate carries a reason" || bad "every gate carries a reason"

# The documented contract is "the plan, then the run_id". Stdio buffering had it
# backwards: the child writes fd 1 unbuffered while our print() is buffered.
# NOT --dry-run: this check is about what a real recording run prints. So it must
# record somewhere harmless — without the override it writes a junk row into the
# real store on every test run, which is exactly the pollution the record exists
# to stay free of.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/plan-test.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
full=$(printf '{"changed_lines":10,"fast_path_eligible_by_size":true,"base_branch":""}' \
	| REVIEW_LOOP_RUNS="$TMP/runs.jsonl" "$PY" plan.py --model test $BOOLS_OFF 2>/dev/null)
last=$(tail -1 <<<"$full")
[[ "$last" =~ ^[0-9a-f]{12}$ ]] && ok "the run_id is the last line, after the plan" || bad "the run_id is the last line, after the plan"
"$PY" -c 'import json,sys; json.loads("\n".join(sys.stdin.read().splitlines()[:-1]))' <<<"$full" \
	&& ok "everything before it parses as the plan JSON" || bad "everything before it parses as the plan JSON"

# The bug this pins: semantic_lines and sizing_excluded were computed, used for every
# threshold, and printed in the plan JSON — then dropped before the record. The checks
# above passed throughout, because they read the JSON this script prints rather than the
# row it persists. A real run recorded `semantic_lines: null` while its own gate reason
# cited "1377 lines of review surface". Assert the PERSISTED row, not the printout.
store="$TMP/persist.jsonl"
rid=$(printf '{"changed_lines":900,"semantic_lines":10,"sizing_excluded":"890 line(s) in lockfiles or generated files","fast_path_eligible_by_size":true,"base_branch":""}' \
	| REVIEW_LOOP_RUNS="$store" "$PY" plan.py --model test $BOOLS_OFF 2>/dev/null | tail -1)
row=$(REVIEW_LOOP_RUNS="$store" "$PY" runlog.py show --run-id "$rid" 2>/dev/null)
"$PY" -c '
import json, sys
d = json.load(sys.stdin)
bad = [k for k, want in (("changed_lines", 900), ("semantic_lines", 10)) if d.get(k) != want]
if not (d.get("sizing_excluded") or "").strip():
    bad.append("sizing_excluded")
# SystemExit("") still exits 1 — an empty "nothing missing" string reads as failure.
raise SystemExit(", ".join(bad) if bad else 0)' <<<"$row" \
	&& ok "the sizing decision reaches the persisted record, not just the printout" \
	|| bad "the sizing decision reaches the persisted record, not just the printout (missing: $("$PY" -c '
import json,sys
d=json.load(sys.stdin)
print(", ".join([k for k,w in (("changed_lines",900),("semantic_lines",10)) if d.get(k)!=w] + ([] if (d.get("sizing_excluded") or "").strip() else ["sizing_excluded"])))' <<<"$row"))"

# A missing context file is a normal mistake, not a stack trace.
err=$("$PY" plan.py --context /nonexistent-context.json --model test $BOOLS_OFF 2>&1)
grep -q Traceback <<<"$err" && bad "a missing context file fails cleanly" || ok "a missing context file fails cleanly"
grep -q "context.sh" <<<"$err" && ok "and says how to fix it" || bad "and says how to fix it"

# --- --dry-run must not touch the store (checked against an isolated one, so a
# --- regression here cannot be masked by unrelated writes to the real store)
export REVIEW_LOOP_RUNS="$TMP/dryrun.jsonl"
plan 10 true $BOOLS_OFF >/dev/null
[ ! -e "$REVIEW_LOOP_RUNS" ] && ok "--dry-run records nothing" || bad "--dry-run records nothing"
unset REVIEW_LOOP_RUNS

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit "$fails"
