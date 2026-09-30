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
[ "$(gate evidence_gate <<<"$p")" = "run" ] && ok "runtime change runs the evidence gate" || bad "runtime change runs the evidence gate"
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

# --- --dry-run must not touch the store
before=$(wc -l < "$HOME/.claude/review-loop/runs.jsonl" 2>/dev/null || echo 0)
plan 10 true $BOOLS_OFF >/dev/null
after=$(wc -l < "$HOME/.claude/review-loop/runs.jsonl" 2>/dev/null || echo 0)
[ "$before" = "$after" ] && ok "--dry-run records nothing" || bad "--dry-run records nothing"

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit "$fails"
