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
checks=0
ok() { echo "  ok  $1"; checks=$((checks + 1)); }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); checks=$((checks + 1)); }

# Isolated from the first invocation, not from line 133. Every plan() and sem() call below
# ran against the ambient store, with --dry-run the only thing keeping them out of the real
# ~/.claude/review-loop/runs.jsonl — and "--dry-run records nothing" is the last check in
# this file, against a different store. So a --dry-run regression polluted the production
# record on every test run before the suite said a word. The record already holds run
# 00b3f14d771e, a test that leaked in exactly this way.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/plan-test.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export REVIEW_LOOP_RUNS="$TMP/ambient.jsonl"

# github_reachable() had no coverage at all — not one of its FIVE outcomes, and no mutation
# entry — while being the function whose whole job is reporting WHICH reason Agent #10 is
# skipped for. A gate reason is read later as evidence, so a wrong one costs more than a
# missing one. All five are covered below. Stubbed via PATH: `git` and `gh` are the only
# externals. `$2` is the remote line, because pinning it to a github URL for every case is
# what left the no-remote branch uncovered while a comment claimed four-of-four.
stubdir() {
	local d="$TMP/stub-$1" remote="$2"; mkdir -p "$d"
	printf '#!/bin/sh\necho "%s"\n' "$remote" > "$d/git"
	chmod +x "$d/git"
	shift 2
	printf '%s\n' "$@" > "$d/gh"
	chmod +x "$d/gh"
	printf '%s' "$d"
}
GH_REMOTE="origin  git@github.com:o/r.git (fetch)"
reason_for() {
	PATH="$1:$PATH" "$PY" -c '
import json, sys
sys.path.insert(0, ".")
import plan
print(json.dumps(plan.github_reachable()))'
}

d=$(stubdir ok "$GH_REMOTE" '#!/bin/sh' 'case "$1" in auth) exit 0 ;; pr) echo "[{\"number\":1}]" ;; esac')
got=$(reason_for "$d")
grep -q '^\[true,' <<<"$got" && grep -q "PR history confirmed" <<<"$got" \
	&& ok "a repo with PRs is reachable, and says the history was confirmed" \
	|| bad "a repo with PRs is reachable ($got)"

d=$(stubdir nopr "$GH_REMOTE" '#!/bin/sh' 'case "$1" in auth) exit 0 ;; pr) echo "[]" ;; esac')
got=$(reason_for "$d")
# Each negative matters as much as its positive: the whole function is about WHICH
# reason, and reporting an auth failure for a repo that simply has no PRs is the bug
# it was written to fix. A test that only checks the right phrase is present passes a
# reason that also claims the wrong one.
grep -q '^\[false,' <<<"$got" && grep -q "no pull requests at all" <<<"$got" \
	&& ! grep -qi "authenticat" <<<"$got" \
	&& ok "a repo with no PRs is skipped for having no PRs, not for auth" \
	|| bad "a repo with no PRs is skipped for the right reason ($got)"

d=$(stubdir noauth "$GH_REMOTE" '#!/bin/sh' 'case "$1" in auth) exit 1 ;; pr) echo "[]" ;; esac')
got=$(reason_for "$d")
grep -q '^\[false,' <<<"$got" && grep -q "not authenticated" <<<"$got" \
	&& ! grep -q "pull requests" <<<"$got" \
	&& ok "an auth failure is reported as an auth failure" \
	|| bad "an auth failure is reported as an auth failure ($got)"

# The probe FAILING is the case that used to fall through to the unconditional success
# line, asserting confirmed PR history that nothing had confirmed — the same defect the
# function's own docstring diagnoses. Fail open, but say the probe failed.
d=$(stubdir prfail "$GH_REMOTE" '#!/bin/sh' 'case "$1" in auth) exit 0 ;; pr) echo "api down" >&2; exit 1 ;; esac')
got=$(reason_for "$d")
grep -q '^\[true,' <<<"$got" && grep -q "could not confirm PR history" <<<"$got" \
	&& ! grep -q "PR history confirmed" <<<"$got" \
	&& ok "a failed probe fails open but does not claim it confirmed anything" \
	|| bad "a failed probe does not claim it confirmed anything ($got)"

# The fifth outcome. No github remote at all short-circuits before either `gh` call, so
# a `gh` stub that would succeed must not change the answer.
d=$(stubdir noremote "origin  git@gitlab.com:o/r.git (fetch)" '#!/bin/sh' 'exit 0')
got=$(reason_for "$d")
grep -q '^\[false,' <<<"$got" && grep -q "no github remote" <<<"$got" \
	&& ! grep -qi "authenticat\|pull requests" <<<"$got" \
	&& ok "no github remote is reported as that, not as auth or missing PRs" \
	|| bad "no github remote is reported as that ($got)"

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
# The sweep gate's reason must name the condition that actually decided it. `due` stopped
# being the bare threshold when the regrowth margin was added and this text did not follow:
# at 40 entries last swept to 36 it said "40 learnings entries — under the 40 threshold",
# false on its face, and sent a reader hunting an off-by-one that did not exist.
sweepreason() {
	printf '{"changed_lines":10,"fast_path_eligible_by_size":false,"base_branch":"","learnings_entries":%s,"learnings_compaction_due":%s,"learnings_swept_entries":%s}' \
		"$1" "$2" "$3" | "$PY" plan.py --model test --dry-run $BOOLS_OFF 2>/dev/null \
		| "$PY" -c 'import json,sys; print(json.load(sys.stdin)["gates"]["staleness_sweep"]["reason"])'
}
r=$(sweepreason 40 false 36)
grep -q "last sweep left 36" <<<"$r" && ! grep -q "under the 40" <<<"$r" \
	&& ok "at the threshold but under the regrowth margin, the reason says so" \
	|| bad "at the threshold but under the regrowth margin, the reason says so ($r)"
r=$(sweepreason 12 false null)
grep -q "under the 40 threshold" <<<"$r" \
	&& ok "genuinely under the threshold still says under the threshold" \
	|| bad "genuinely under the threshold still says under the threshold ($r)"
r=$(sweepreason 44 true 36)
grep -q "at/over the 40 threshold" <<<"$r" && ! grep -q "last sweep" <<<"$r" \
	&& ok "and a due sweep says the threshold was crossed" \
	|| bad "and a due sweep says the threshold was crossed ($r)"

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
bad = [k for k, want in (("changed_lines", 900), ("semantic_lines", 10),
                         ("agent_cap", 40)) if d.get(k) != want]
# tier_reason was asserted only from the PRINTOUT above, and plan.py passed no
# --tier-reason, so the key never existed in the row — the same bug shape in the same
# block that exists to pin it. Run faafc47dcd29 recorded tier_reason null beside
# semantic_lines 1508.
for k in ("sizing_excluded", "tier_reason"):
    if not (d.get(k) or "").strip():
        bad.append(k)
# SystemExit("") still exits 1 — an empty "nothing missing" string reads as failure.
raise SystemExit(", ".join(bad) if bad else 0)' <<<"$row" \
	&& ok "the sizing decision reaches the persisted record, not just the printout" \
	|| bad "the sizing decision reaches the persisted record, not just the printout (missing: $("$PY" -c '
import json,sys
d=json.load(sys.stdin)
print(", ".join([k for k,w in (("changed_lines",900),("semantic_lines",10),("agent_cap",40)) if d.get(k)!=w] + [k for k in ("sizing_excluded","tier_reason") if not (d.get(k) or "").strip()]))' <<<"$row"))"

# A missing context file is a normal mistake, not a stack trace.
err=$("$PY" plan.py --context /nonexistent-context.json --model test $BOOLS_OFF 2>&1)
grep -q Traceback <<<"$err" && bad "a missing context file fails cleanly" || ok "a missing context file fails cleanly"
grep -q "context.sh" <<<"$err" && ok "and says how to fix it" || bad "and says how to fix it"

# --- --dry-run must not touch the store (checked against an isolated one, so a
# --- regression here cannot be masked by unrelated writes to the real store)
export REVIEW_LOOP_RUNS="$TMP/dryrun.jsonl"
plan 10 true $BOOLS_OFF >/dev/null
[ ! -e "$REVIEW_LOOP_RUNS" ] && ok "--dry-run records nothing" || bad "--dry-run records nothing"
export REVIEW_LOOP_RUNS="$TMP/ambient.jsonl"

echo
# An assertion that VANISHES is invisible without a count. Two ways it has happened
# here: a syntax error inside a `cond && ok || bad` list abandons the whole list so
# NEITHER branch runs, and assertions appended below this summary never execute at all
# (six did, once). shellcheck flags the idiom ~109 times across these suites and cannot
# tell a deliberate one from a broken one — this can.
#
# Raise EXPECTED_CHECKS deliberately when you add an assertion. That edit is the review
# trail, the same way the mutation-catalog floor works.
EXPECTED_CHECKS=40
if [ "$checks" -ne "$EXPECTED_CHECKS" ]; then
	echo "ran $checks checks, expected $EXPECTED_CHECKS — an assertion vanished, or one was added without raising EXPECTED_CHECKS"
	fails=$((fails + 1))
fi
[ "$fails" -eq 0 ] && echo "all checks passed ($checks checks)" || echo "$fails check(s) failed"
exit "$fails"
