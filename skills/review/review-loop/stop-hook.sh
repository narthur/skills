#!/bin/bash
# review-loop Stop hook: a session may not end with a planned run it never finished.
#
# pre-push cannot reach this. A session that runs the loop and then stops WITHOUT
# pushing drops its gates completely unobserved — which is how PR #1359 lost the
# threat-model update, the staleness sweep, learnings capture, the #10 retry, and
# the Step 14 comment while still recording a clean exit.
#
# Stop fires at EVERY turn boundary, not only when a session ends, so a run that
# is merely mid-flight trips this. It therefore prompts once per run (recorded as
# a `nudge`) and then stays quiet: it never blocks twice, and it never writes an
# outcome. Marking a still-running review `abandoned` from here would corrupt the
# record this hook exists to keep honest, and no hook can tell mid-flight from
# dead. Abandonment is derived on read instead — review-stats.py counts an open
# run from a session that is no longer current. A deliberate interrupt or a dead
# subprocess costs one prompt, never a trapped session and never a false outcome.
#
# Register in settings.json:
#   "Stop": [{"hooks": [{"type": "command",
#              "command": "~/.claude/skills/review-loop/stop-hook.sh"}]}]
set -uo pipefail

input=$(cat)

# This fires on EVERY Stop in every session on the machine, so the no-run case —
# overwhelmingly the common one — must cost nothing. An empty or absent store
# means nothing was ever planned, so leave before spawning git or python.
STORE="${REVIEW_LOOP_RUNS:-$HOME/.claude/review-loop/runs.jsonl}"
[ -s "$STORE" ] || exit 0

# Sibling first, then the installed location. These ship together, so the copy next to
# this script is the one whose version matches it — and resolving only through $HOME meant
# the hook silently exit 0'd anywhere the skill was not installed, including CI. That is
# why runlog.test.sh's four stop-hook assertions passed here and went red on the first
# runner that ever ran them: the suite was exercising the INSTALLED hook, not the checked-
# out one, and on a machine without the install there was nothing to exercise at all.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNLOG="$HERE/runlog.py"
[ -x "$RUNLOG" ] || RUNLOG="$HOME/.claude/skills/review-loop/runlog.py"
[ -x "$RUNLOG" ] || exit 0

# The hook runs from the session's cwd, but a Stop can fire anywhere; only a git
# work tree can have an open run.
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
# Scope to the commit this session is actually standing in front of. Without it,
# a linked worktree's run — or one from a branch this session has since left —
# is what surfaces, so the hook can nag about an unrelated run or be masked by a
# newer one and stay silent about the relevant one.
head=$(git rev-parse HEAD 2>/dev/null)

py=$(command -v python3.14 || command -v python3) || exit 0
sid=$("$py" -c 'import json,sys; print(json.load(sys.stdin).get("session_id") or "")' <<<"$input" 2>/dev/null)
open=$("$py" "$RUNLOG" check ${sid:+--session "$sid"} ${head:+--head "$head"} 2>/dev/null)
status=$?
[ "$status" -eq 1 ] || exit 0   # 0 = nothing open; anything else = broken, never block on that

run_id=$("$py" -c 'import json,sys; print(json.load(sys.stdin).get("run_id",""))' <<<"$open" 2>/dev/null)
gates=$("$py" -c 'import json,sys; print(", ".join(json.load(sys.stdin).get("planned_gates") or []) or "(none listed)")' <<<"$open" 2>/dev/null)
[ -n "$run_id" ] || exit 0

reason="review-loop run ${run_id} was planned but never finished. Planned gates: ${gates}.

Either complete the remaining steps and record the result:
  python3 ~/.claude/skills/review-loop/runlog.py finish --run-id ${run_id} --outcome <clean|cycle-limit|test-failure|blocked> --tier <fast|full|partial> --executed '{\"<gate>\":{\"status\":\"done|skipped|failed\",\"reason\":\"...\"}}' --asks <n>

or, if the run is still in flight, carry on — this prompt fires once per run and will not interrupt you again. If you are stopping for good without finishing, say which gates you are not running and why, and record it:
  python3 ~/.claude/skills/review-loop/runlog.py abandon --run-id ${run_id} --missing '<gates you are not running>' 

A skipped gate is fine; a silently skipped gate is what this hook exists to prevent. Reasons citing existing precedent in the repo are rejected: a copied pattern carries its bugs."

# Mark the run nudged only once the prompt has actually been delivered. A nudge
# silences this run for good, so writing it first would mean a failed print
# swallows the only warning the run ever gets — a flag set before the action it
# is meant to gate.
"$py" -c 'import json,sys; print(json.dumps({"decision":"block","reason":sys.stdin.read()}))' <<<"$reason" \
	&& "$py" "$RUNLOG" nudge --run-id "$run_id" >/dev/null 2>&1
exit 0
