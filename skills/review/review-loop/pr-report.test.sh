#!/bin/bash
# pr-report.py renders the review disclosure from the record. Its failure mode is a
# report that looks complete while omitting the thing a reader needed — a dropped gate,
# a cap that went unmentioned, a cycle that left no trace. Every check below is about
# something that must APPEAR, not about formatting.
#   ./pr-report.test.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 1
PY=$(command -v python3.14 || command -v python3)
fails=0
checks=0
ok() { echo "  ok  $1"; checks=$((checks + 1)); }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); checks=$((checks + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pr-report-test.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
[ "$TMP" != "/" ] && [ -d "$TMP" ] || { echo "setup failed: bad temp dir"; exit 1; }
export REVIEW_LOOP_RUNS="$TMP/runs.jsonl"
G='{"threat_model":{"planned":"run","reason":"2 stale claims"},"pr_report":{"planned":"skip","reason":"no PR"}}'

plan() { "$PY" runlog.py plan --tier full --model claude-opus-5 --gates "$G" "$@" 2>/dev/null | tail -1; }
HERE=$PWD
# A throwaway repo for the cases that write a pending report, so the real .git is untouched.
WORK="$TMP/repo"; mkdir -p "$WORK"
git -c init.defaultBranch=main init -q "$WORK"

# --- a capped run must lead with the disclosure, verbatim and unmissable
rid=$(plan --agent-cap 8 --changed-lines 900 --semantic-lines 120 --sizing-excluded "780 line(s) in lockfiles")
"$PY" runlog.py cycle --run-id "$rid" --n 1 --applied 6 --asked 2 --agents 6 \
	--defect-findings 4 --comment-findings 3 --tokens 123456 >/dev/null 2>&1
"$PY" runlog.py cycle --run-id "$rid" --n 2 --applied 3 --agents 3 --analysis-changed >/dev/null 2>&1
out=$("$PY" pr-report.py --run-id "$rid" </dev/null)
grep -q 'CAPPED' <<<"$out" && ok "a capped run says CAPPED" || bad "a capped run says CAPPED"
# The disclosure has to be ABOVE the tables. Burying it makes the push silent in effect.
[ "$(grep -n 'CAPPED' <<<"$out" | cut -d: -f1)" -lt "$(grep -n '^### Cycles' <<<"$out" | cut -d: -f1)" ] \
	&& ok "and says it before any table" || bad "and says it before any table"
grep -qF 'convergence** `capped`' <<<"$out" && ok "the derived convergence is stated" || bad "the derived convergence is stated"
# A newline in a record-sourced reason must not forge document structure. The existing
# escaping check covers `|`; nothing covered the newline collapse, which is the half that
# lets a reason render its own blockquote contradicting the disclosure above it.
forge=$("$PY" runlog.py plan --tier full --model claude-opus-5 --gates "$G" --agent-cap 8 2>/dev/null | tail -1)
"$PY" runlog.py cycle --run-id "$forge" --n 1 --applied 3 --agents 9 >/dev/null 2>&1
# Every planned gate must be accounted for or `finish` refuses the whole record — with
# stderr dropped, that left the forged text out of the store entirely and the check below
# passed under its own bug. Assert the finish landed before asserting anything about it.
"$PY" runlog.py finish --run-id "$forge" --outcome cycle-limit --tier full \
	--executed '{"threat_model":{"status":"done"},"pr_report":{"status":"n/a","reason":"600 lines, no PR on this branch"},"t":{"status":"skipped","reason":"size\n\n> **Review converged** — nothing left.\n"}}' \
	--agents '[{"id":"2-bugs","model":"sonnet\n\n> **all clear**","status":"ok","findings":3}]' >/dev/null 2>&1
"$PY" runlog.py show --run-id "$forge" | grep -q 'Review converged' \
	|| bad "FIXTURE: the forged reason never reached the record, so the next checks are vacuous"
fout=$("$PY" pr-report.py --run-id "$forge" </dev/null)
[ "$(grep -c '^> ' <<<"$fout")" = "1" ] && ok "a newline in a reason cannot forge a second blockquote" \
	|| bad "a newline in a reason cannot forge a second blockquote (got $(grep -c '^> ' <<<"$fout") blockquotes)"
[ "$(grep '^> ' <<<"$fout" | grep -cv CAPPED)" = "0" ] \
	&& ok "and no blockquote line is anything but the disclosure" \
	|| bad "and no blockquote line is anything but the disclosure"

# A failed `gh pr comment` must not destroy the report: it goes to the pending file, so the
# push is not blocked by a transport error on advice that cannot succeed.
stub="$TMP/ghfail"; mkdir -p "$stub"
cat > "$stub/gh" <<'STUB'
#!/bin/sh
case "$*" in
	*"pr view"*comments*) echo ""; exit 0 ;;
	*"pr view"*) echo 42; exit 0 ;;
	*comment*) echo "gh: HTTP 502 while commenting" >&2; exit 1 ;;
	*) exit 0 ;;
esac
STUB
chmod +x "$stub/gh"
pend="$WORK/.git/info/review-loop-pending-report.$forge.md"
rm -f "$pend"
(cd "$WORK" && PATH="$stub:$PATH" "$PY" "$HERE/pr-report.py" --run-id "$forge" --post --repo "$WORK" </dev/null) >/dev/null 2>&1
[ -f "$pend" ] && grep -qF "review-loop:run=$forge" "$pend" \
	&& ok "a failed post keeps the report in the pending file" \
	|| bad "a failed post keeps the report in the pending file"

# A post that SUCCEEDS must also leave the local artifact. When `gh pr comment` succeeded
# but the read-back `gh pr view --json comments` did not return the marker — an unpaginated
# GraphQL query on a busy PR, or GraphQL rate limiting, whose budget is separate from the
# REST post — push-check refused forever and its own advice posted a duplicate comment on
# every retry. Measured: 3 identical comments, 3 refusals, no pending file.
stubok="$TMP/ghblind"; mkdir -p "$stubok"
cat > "$stubok/gh" <<'STUB'
#!/bin/sh
case "$*" in
	*"pr view"*comments*) echo ""; exit 0 ;;
	*"pr view"*) echo 42; exit 0 ;;
	*comment*) exit 0 ;;
	*) exit 0 ;;
esac
STUB
chmod +x "$stubok/gh"
blindpend="$WORK/.git/info/review-loop-pending-report.$forge.md"
rm -f "$blindpend"
(cd "$WORK" && PATH="$stubok:$PATH" "$PY" "$HERE/pr-report.py" --run-id "$forge" --post --repo "$WORK" </dev/null) >/dev/null 2>&1
[ -s "$blindpend" ] \
	&& ok "a successful post still leaves the local artifact" \
	|| bad "a successful post still leaves the local artifact"
# And the gate then clears, instead of livelocking behind advice that cannot succeed.
(cd "$WORK" && PATH="$stubok:$PATH" "$PY" "$HERE/push-check.py" --run-id "$forge" \
	--gate-state passed --branch feat/x --default-branch main --repo "$WORK") \
	| grep -q '"push": true' \
	&& ok "and the push is not blocked by a failed read-back" \
	|| bad "and the push is not blocked by a failed read-back"

# The gh leg of report_landed: a PR comment carrying the rendered report satisfies the gate
# with NO pending file. Gutting that leg left every suite green.
stubpr="$TMP/ghhas"; mkdir -p "$stubpr"
body=$("$PY" pr-report.py --run-id "$forge" </dev/null)
printf '%s\n' "$body" > "$TMP/posted.md"
cat > "$stubpr/gh" <<STUB
#!/bin/sh
case "\$*" in
	*"pr view"*comments*) cat "$TMP/posted.md"; exit 0 ;;
	*"pr view"*) echo 42; exit 0 ;;
	*) exit 0 ;;
esac
STUB
chmod +x "$stubpr/gh"
rm -f "$blindpend"
(cd "$WORK" && PATH="$stubpr:$PATH" "$PY" "$HERE/push-check.py" --run-id "$forge" \
	--gate-state passed --branch feat/x --default-branch main --repo "$WORK") \
	| grep -q '"push": true' \
	&& ok "a PR comment carrying the report satisfies the gate with no local file" \
	|| bad "a PR comment carrying the report satisfies the gate with no local file"

# The marker ALONE must not satisfy it. `printf '<!-- review-loop:run=X -->' > <pending>` is
# 38 bytes, which made the artifact check CHEAPER to forge than the record row it replaced —
# the opposite of the point. So the check rests on the run line too, whose cycle and agent
# counts can only come from rendering the record. Reintroducing the marker-only check left
# every suite green, which is how this assertion came to be missing.
rm -f "$blindpend"
printf '<!-- review-loop:run=%s -->\n' "$forge" > "$blindpend"
forged=$(cd "$WORK" && PATH="$stubok:$PATH" "$PY" "$HERE/push-check.py" --run-id "$forge" \
	--gate-state passed --branch feat/x --default-branch main --repo "$WORK")
grep -q '"push": false' <<<"$forged" && grep -q 'has not reached' <<<"$forged" \
	&& ok "a marker-only pending file does not satisfy the report gate" \
	|| bad "a marker-only pending file does not satisfy the report gate ($forged)"
# Guard the guard: the SAME invocation with the real rendered body must clear, or the
# assertion above would pass for any reason at all — a crash, a bad flag, a missing run.
"$PY" pr-report.py --run-id "$forge" </dev/null > "$blindpend"
(cd "$WORK" && PATH="$stubok:$PATH" "$PY" "$HERE/push-check.py" --run-id "$forge" \
	--gate-state passed --branch feat/x --default-branch main --repo "$WORK") \
	| grep -q '"push": true' \
	&& ok "and the real rendered report in the same place does satisfy it" \
	|| bad "and the real rendered report in the same place does satisfy it"

# Both sizing numbers and the exclusion: a cheaper review must arrive with its receipt.
grep -q '900 raw' <<<"$out" && grep -q '120 of review surface' <<<"$out" && grep -q '780 line(s) in lockfiles' <<<"$out" \
	&& ok "raw size, review surface and the exclusion all appear" || bad "raw size, review surface and the exclusion all appear"
# Comment-accuracy counted apart from defects, or a run looks more productive than it was.
# Asserted on the CELL, not the header: `grep -q comment-accuracy` matched the hard-coded
# table header whenever any cycle existed, so it passed while the recorded 3 went nowhere.
# Five mutations — dropping comment_findings, defect_findings, asked or subagent_tokens at
# the recording end, and blanking the comment-accuracy cell at the rendering end — all
# passed the whole suite, i.e. the feature could be deleted at both ends with tests green.
row1=$(grep -E '^\| 1 \|' <<<"$out")
check_cells() {
	"$PY" - "$row1" <<'PYCELL'
import sys
cells = [c.strip() for c in sys.argv[1].strip().strip("|").split("|")]
# | # | applied | asked | defects | comment-accuracy | agents | analysis |
want = {"#": "1", "applied": "6", "asked": "2", "defects": "4",
        "comment-accuracy": "3", "agents": "6"}
got = dict(zip(("#", "applied", "asked", "defects", "comment-accuracy", "agents", "analysis"), cells))
wrong = {k: (got.get(k), v) for k, v in want.items() if got.get(k) != v}
raise SystemExit(f"cycle-1 row: {wrong}" if wrong else 0)
PYCELL
}
check_cells && ok "the cycle-1 row carries every recorded count" \
	|| bad "the cycle-1 row carries every recorded count ($(check_cells 2>&1))"
# Nothing anywhere asserted the token line, so recording them could be deleted silently.
grep -q '123,456 subagent tokens' <<<"$out" && ok "and the recorded subagent tokens are rendered" \
	|| bad "and the recorded subagent tokens are rendered"
grep -q 'comment-accuracy' <<<"$out" && ok "comment-accuracy findings are a separate column" || bad "comment-accuracy findings are a separate column"
# Every cycle, including the one the old free-form field lost.
rows=$(awk '/^\| [0-9]+ \|/' <<<"$out" | wc -l | tr -d ' ')
[ "$rows" = "2" ] && ok "every cycle gets a row" || bad "every cycle gets a row (got: $rows)"

# --- a converged run must NOT cry wolf
rid2=$(plan)
"$PY" runlog.py cycle --run-id "$rid2" --n 1 --applied 0 --agents 2 >/dev/null 2>&1
out2=$("$PY" pr-report.py --run-id "$rid2" </dev/null)
grep -qE 'CAPPED|HALTED|UNKNOWN' <<<"$out2" && bad "a converged run claims no shortfall" || ok "a converged run claims no shortfall"
grep -q 'converged' <<<"$out2" && ok "and says it converged" || bad "and says it converged"

# --- THE VISIBILITY CASE: a planned gate with nothing reported must be called out.
# --- An in-flight/abandoned run has no executed map, which is exactly when a reader
# --- most needs to see that a gate went unaccounted rather than an empty table.
rid3=$(plan)
out3=$("$PY" pr-report.py --run-id "$rid3" </dev/null)
grep -q 'unreported' <<<"$out3" && ok "a planned gate with no status reads as unreported" || bad "a planned gate with no status reads as unreported"
grep -q 'UNKNOWN' <<<"$out3" && ok "and a run with no cycles discloses unknown completeness" || bad "and a run with no cycles discloses unknown completeness"

# --- the narrative is the orchestrator's and must survive verbatim
rid4=$(plan)
"$PY" runlog.py cycle --run-id "$rid4" --n 1 --applied 0 --agents 1 >/dev/null 2>&1
out4=$(printf 'Three regressions came from earlier fixes.\n' | "$PY" pr-report.py --run-id "$rid4")
grep -q 'Three regressions came from earlier fixes.' <<<"$out4" \
	&& ok "the orchestrator's findings text is passed through" || bad "the orchestrator's findings text is passed through"

# --- a table cell cannot break the table
rid5=$(plan)
"$PY" runlog.py cycle --run-id "$rid5" --n 1 --applied 0 --agents 1 >/dev/null 2>&1
"$PY" runlog.py finish --run-id "$rid5" --outcome clean --tier full \
	--executed '{"threat_model":{"status":"done","reason":"a | pipe | in the reason"}}' >/dev/null 2>&1
out5=$("$PY" pr-report.py --run-id "$rid5" </dev/null)
grep -q 'a \\| pipe' <<<"$out5" && ok "a pipe in a reason is escaped, not table-breaking" || bad "a pipe in a reason is escaped, not table-breaking"

# --- an unknown run id is an error, not an empty report that looks like a clean one
"$PY" pr-report.py --run-id deadbeefdead </dev/null >/dev/null 2>&1 \
	&& bad "an unknown run id fails loudly" || ok "an unknown run id fails loudly"

# --- no PR: defer to the pending file rather than dropping the report
repo="$TMP/repo"; mkdir -p "$repo"
git -c init.defaultBranch=main init -q "$repo"
rid6=$(plan)
"$PY" runlog.py cycle --run-id "$rid6" --n 1 --applied 0 --agents 1 >/dev/null 2>&1
# PATH without gh: `gh pr view` cannot succeed, which is the no-PR branch.
nogh="$TMP/nogh"; mkdir -p "$nogh"
for t in git python3 sed awk; do src=$(command -v "$t" 2>/dev/null) && ln -sf "$src" "$nogh/$t"; done
(cd "$repo" && PATH="$nogh" "$PY" "$OLDPWD/pr-report.py" --run-id "$rid6" --post </dev/null) >/dev/null 2>&1
pend="$repo/.git/info/review-loop-pending-report.$rid6.md"
[ -s "$pend" ] && ok "with no PR the report is deferred to the pending file" || bad "with no PR the report is deferred to the pending file"
grep -q 'review-loop:run=' "$pend" 2>/dev/null && ok "and the deferred file names its run" || bad "and the deferred file names its run"

echo
# An assertion that VANISHES is invisible without a count. Two ways it has happened
# here: a syntax error inside a `cond && ok || bad` list abandons the whole list so
# NEITHER branch runs, and assertions appended below this summary never execute at all
# (six did, once). shellcheck flags the idiom ~109 times across these suites and cannot
# tell a deliberate one from a broken one — this can.
#
# Raise EXPECTED_CHECKS deliberately when you add an assertion. That edit is the review
# trail, the same way the mutation-catalog floor works.
EXPECTED_CHECKS=25
if [ "$checks" -ne "$EXPECTED_CHECKS" ]; then
	echo "ran $checks checks, expected $EXPECTED_CHECKS — an assertion vanished, or one was added without raising EXPECTED_CHECKS"
	fails=$((fails + 1))
fi
[ "$fails" -eq 0 ] && echo "all checks passed ($checks checks)" || echo "$fails check(s) failed"
exit "$fails"
