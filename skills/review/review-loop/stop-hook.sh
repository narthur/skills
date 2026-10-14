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
# dead. Abandonment is derived on read instead — `looper stats` counts an open
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

# The hook runs from the session's cwd, but a Stop can fire anywhere; only a git
# work tree can have an open run.
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
# Scope to the commit this session is actually standing in front of. Without it,
# a linked worktree's run — or one from a branch this session has since left —
# is what surfaces, so the hook can nag about an unrelated run or be masked by a
# newer one and stay silent about the relevant one.
head=$(git rev-parse HEAD 2>/dev/null)

# -I on every call below: the hook runs in the session's cwd, which is a repo, and plain
# `python3 -c` puts that directory first on sys.path, so a json.py there would run here.
# No python at all is said in fixed JSON, which needs none: silence would read as nothing open.
py=$(command -v python3.14 || command -v python3) || {
	printf '%s\n' '{"systemMessage": "review-loop Stop hook: no python3 on PATH, so open review-loop runs cannot be checked"}'
	exit 0
}

# Never block on the hook's own breakage, but never swallow it either: a hook that exits
# 0 silently when it cannot read the record is indistinguishable from one that found
# nothing open, and that silence is how a dropped gate goes unseen. systemMessage is shown
# to the user and blocks nothing.
warn() {
	"$py" -I -c 'import json,sys; print(json.dumps({"systemMessage": "review-loop Stop hook: " + sys.stdin.read().strip()}))' <<<"$1"
	exit 0
}

# By absolute path, never PATH (SKILL.md Step 0 says why). The store is non-empty, so a run
# may well be open, and without looper nothing here can say whether one is.
LOOPER="$HOME/.local/bin/looper"
[ -x "$LOOPER" ] || warn "$LOOPER is missing, so unfinished review-loop runs are not being checked. Install it (SKILL.md Step 0): GOBIN=~/.local/bin go install github.com/pinepeakdigital/looper/cmd/looper@v0.2.7"

sid=$("$py" -I -c 'import json,sys; print(json.load(sys.stdin).get("session_id") or "")' <<<"$input" 2>/dev/null)
errf=$(mktemp "${TMPDIR:-/tmp}/review-loop-stop.XXXXXX") || warn "could not create a temp file to run the unfinished-run check"
open=$("$LOOPER" record check ${sid:+--session "$sid"} ${head:+--head "$head"} 2>"$errf")
status=$?
err=$(cat "$errf" 2>/dev/null); rm -f "$errf"
[ "$status" -eq 0 ] && exit 0   # nothing open
# check exits 1 for two reasons: a run is open (the JSON is on stdout), or the store could
# not be read (stdout empty, the reason on stderr). Anything else is breakage too.
if [ "$status" -ne 1 ] || [ -z "$open" ]; then
	warn "could not check for unfinished review-loop runs (looper record check exited $status): ${err:-no message}"
fi

run_id=$("$py" -I -c 'import json,sys; print(json.load(sys.stdin).get("run_id",""))' <<<"$open" 2>/dev/null)
gates=$("$py" -I -c 'import json,sys; print(", ".join(json.load(sys.stdin).get("planned_gates") or []) or "(none listed)")' <<<"$open" 2>/dev/null)
[ -n "$run_id" ] || exit 0

reason="review-loop run ${run_id} was planned but never finished. Planned gates: ${gates}.

Either complete the remaining steps and record the result:
  ~/.local/bin/looper record finish --run-id ${run_id} --outcome <clean|cycle-limit|test-failure|blocked> --tier <fast|full|partial> --executed '{\"<gate>\":{\"status\":\"done|skipped|failed\",\"reason\":\"...\"}}' --asks <n>

or, if the run is still in flight, carry on — this prompt fires once per run and will not interrupt you again. If you are stopping for good without finishing, say which gates you are not running and why, and record it:
  ~/.local/bin/looper record abandon --run-id ${run_id} --missing '<gates you are not running>' 

A skipped gate is fine; a silently skipped gate is what this hook exists to prevent. Reasons citing existing precedent in the repo are rejected: a copied pattern carries its bugs."

# Mark the run nudged only once the prompt exists. A nudge silences this run for good, so
# writing it before the block JSON is built would mean a failed build swallows the only
# warning the run ever gets — a flag set before the action it is meant to gate. What is left
# after the build is a printf of a finished string, which fails only on a closed stdout.
#
# A FAILED nudge is said, not discarded: the run stays un-nudged, so the block comes back on
# every Stop, and without a reason that reads as the hook misbehaving. A hook emits one JSON
# object, so the diagnostic rides in it as a systemMessage beside the block.
out=$("$py" -I -c 'import json,sys; print(json.dumps({"decision":"block","reason":sys.stdin.read()}))' <<<"$reason") || exit 0
# Into o2, not out: a failed substitution still assigns, and would replace the block with nothing.
if ! nerr=$("$LOOPER" record nudge --run-id "$run_id" 2>&1 >/dev/null) &&
	o2=$("$py" -I -c 'import json,sys
d = json.loads(sys.argv[1])
d["systemMessage"] = ("review-loop Stop hook: could not mark run " + sys.argv[2] +
                      " as prompted, so this block will repeat on every stop: " + (sys.argv[3].strip() or "no error text"))
print(json.dumps(d))' "$out" "$run_id" "$nerr"); then
	out=$o2
fi
printf '%s\n' "$out"
exit 0
