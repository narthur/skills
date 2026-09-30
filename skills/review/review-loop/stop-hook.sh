#!/bin/bash
# review-loop Stop hook: a session may not end with a planned run it never finished.
#
# pre-push cannot reach this. A session that runs the loop and then stops WITHOUT
# pushing drops its gates completely unobserved — which is how PR #1359 lost the
# threat-model update, the staleness sweep, learnings capture, the #10 retry, and
# the Step 14 comment while still recording a clean exit.
#
# Bounded by the harness's own `stop_hook_active`: the first Stop blocks with the
# list of unfinished gates, the second records the run as abandoned and lets the
# session end. A deliberate interrupt or a dead subprocess can never trap a session.
#
# Register in settings.json:
#   "Stop": [{"hooks": [{"type": "command",
#              "command": "~/.claude/skills/review-loop/stop-hook.sh"}]}]
set -uo pipefail

input=$(cat)
RUNLOG="$HOME/.claude/skills/review-loop/runlog.py"
[ -x "$RUNLOG" ] || exit 0

# The hook runs from the session's cwd, but a Stop can fire anywhere; only a git
# work tree can have an open run.
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

py=$(command -v python3.14 || command -v python3) || exit 0
sid=$("$py" -c 'import json,sys; print(json.load(sys.stdin).get("session_id") or "")' <<<"$input" 2>/dev/null)
open=$("$py" "$RUNLOG" check ${sid:+--session "$sid"} 2>/dev/null)
status=$?
[ "$status" -eq 1 ] || exit 0   # 0 = nothing open; anything else = broken, never block on that

run_id=$("$py" -c 'import json,sys; print(json.load(sys.stdin).get("run_id",""))' <<<"$open" 2>/dev/null)
gates=$("$py" -c 'import json,sys; print(", ".join(json.load(sys.stdin).get("planned_gates") or []) or "(none listed)")' <<<"$open" 2>/dev/null)
[ -n "$run_id" ] || exit 0

already=$("$py" -c 'import json,sys; print("1" if json.load(sys.stdin).get("stop_hook_active") else "")' <<<"$input" 2>/dev/null)

if [ -n "$already" ]; then
	# Second Stop: record the truth and get out of the way.
	"$py" "$RUNLOG" abandon --run-id "$run_id" --missing "$gates" >/dev/null 2>&1
	exit 0
fi

reason="review-loop run ${run_id} was planned but never finished. Planned gates: ${gates}.

Either complete the remaining steps and record the result:
  python3 ~/.claude/skills/review-loop/runlog.py finish --run-id ${run_id} --outcome <clean|cycle-limit|test-failure|blocked> --tier <fast|full|partial> --executed '{\"<gate>\":{\"status\":\"done|skipped|failed\",\"reason\":\"...\"}}' --asks <n>

or say plainly in your reply which gates you are not running and why, then stop again — the next Stop records the run as abandoned rather than blocking.

A skipped gate is fine; a silently skipped gate is what this hook exists to prevent. Reasons citing existing precedent in the repo are rejected: a copied pattern carries its bugs."

"$py" -c 'import json,sys; print(json.dumps({"decision":"block","reason":sys.stdin.read()}))' <<<"$reason"
exit 0
