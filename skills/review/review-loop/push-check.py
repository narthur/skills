#!/usr/bin/env python3
"""Deterministic auto-push eligibility for review-loop Step 14.

Combines loop state with git facts (checked here) into one push/no-push decision +
reason, so the safety-relevant "never push to the default branch" logic isn't
re-derived in prose each run.

  push-check.py --run-id <id> --gate-state passed --branch feat/x --default-branch main
  push-check.py --selftest

Emits JSON {push, reason, convergence, disclose}.

Convergence is READ FROM THE RECORD, not passed in. It used to arrive as
`--clean-exit`, a bare flag, so the one question this script exists to answer — was
this change finished being reviewed — was answered by the orchestrator asserting it.
Run b480b45cc65d recorded outcome `clean` for a run its own author reported as not
converged; nothing could have caught that.

And not converging no longer blocks the push, because a cap that strands commits just
moves the decision back to a human every time. A capped or halted run pushes and
OWES A DISCLOSURE: `disclose` carries the line the PR must say. What still blocks is a
different question — a blocked evidence gate, an unresolved finding, the default
branch — which is "this is broken", not "we stopped looking".
"""
import argparse
import json
import subprocess
import sys

# Plain import: the executed script's own directory is sys.path[0], and runlog is the
# single definition of how convergence is derived. Restating the derivation here is how
# the two would drift — the mistake this whole field exists to correct.
import runlog


def decide(convergence, gate_state, unresolved_skip, branch, default_branch, upstream_exists):
    """First failing check wins — mirrors Step 14 'When NOT to auto-push'.

    `convergence` is "converged", "capped", "halted", or None/"unknown" when the run
    recorded no cycles. Only "converged" needs no disclosure; everything else — None
    included, so omitting the cycle rows can never buy a silent push — pushes with one.
    """
    if gate_state == "blocked":
        return False, "evidence gate blocked or hit its restart cap"
    if unresolved_skip:
        return False, "a 50-79 finding was skipped without 'remember as dismissal' — unresolved"
    if not branch or not default_branch:
        # Fail closed: an unknown name would skip the default-branch guard below.
        return False, "current or default branch unknown — refusing to push"
    if branch == default_branch:
        return False, f"branch is the default branch ({branch}) — never auto-push to it"
    where = ("feature branch has no upstream yet — push with -u" if not upstream_exists
             # First push of a new feature branch is the normal case, not a block. SKILL.md
             # Step 14 pushes it with `-u origin`. The old "don't infer an upstream" rule
             # blocked every fresh branch (changed 2026-09-17).
             else "feature branch with upstream")
    if convergence == "converged":
        return True, f"converged, evidence gate ok, {where}"
    return True, f"{convergence or 'unknown'} (review not finished), evidence gate ok, {where}"


def _upstream_exists(repo):
    r = subprocess.run(["git", "-C", repo, "rev-parse", "--abbrev-ref", "@{upstream}"],
                       capture_output=True, text=True, check=False)
    return r.returncode == 0


def _selftest():
    ok = ("feat/x", "main", True)
    # Converged pushes with no disclosure.
    assert decide("converged", "passed", False, *ok)[0] is True
    assert decide("converged", "skipped", False, *ok)[0] is True
    assert runlog.disclosure("converged", {}) is None
    # Not converging no longer BLOCKS — it obliges a disclosure. This is the behaviour
    # change: a cap that strands commits just hands the decision back to a human.
    for c in ("capped", "halted", None):
        push, reason = decide(c, "passed", False, *ok)
        assert push is True, c
        assert "not finished" in reason, reason
        assert runlog.disclosure(c, {"agent_cap": 8, "cycles": [{"n": 1, "applied": 3, "agents": 9}]})
    # Unknown convergence must still disclose — omitting cycle rows cannot buy silence.
    assert "UNKNOWN" in runlog.disclosure(None, {})
    # What genuinely blocks is a different question: broken, not unfinished.
    assert decide("converged", "blocked", False, *ok)[0] is False           # gate blocked
    assert decide("converged", "passed", True, *ok)[0] is False             # unresolved skip
    assert decide("converged", "passed", False, "main", "main", True)[0] is False   # default branch
    first = decide("converged", "passed", False, "feat/x", "main", False)
    assert first[0] is True and "-u" in first[1]
    assert decide("converged", "passed", False, "main", "", False)[0] is False   # default unknown
    assert decide("converged", "passed", False, "", "main", True)[0] is False    # branch unknown
    assert decide("converged", "passed", False, "main", "main", False)[0] is False
    # A blocked gate outranks convergence either way, so an unconverged run cannot push
    # past a real blocker by virtue of being merely unfinished.
    assert decide("capped", "blocked", False, *ok)[0] is False
    print("ok")


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-id", help="read convergence from the run record (required unless --selftest)")
    ap.add_argument("--gate-state", choices=["passed", "skipped", "blocked"], default="skipped")
    ap.add_argument("--unresolved-skip", action="store_true")
    ap.add_argument("--branch", default="")
    ap.add_argument("--default-branch", default="")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        _selftest()
        return 0
    # No --run-id means no record to read, which is not the same as converged. Fail
    # closed the way a missing cycle row does: push, but disclose that nothing is known.
    run, conv = {}, None
    if a.run_id:
        run = runlog.load(limit=None).get(a.run_id) or {}
        conv = runlog.convergence(run)
    push, reason = decide(conv, a.gate_state, a.unresolved_skip,
                          a.branch, a.default_branch, _upstream_exists(a.repo))
    print(json.dumps({"push": push, "reason": reason,
                      "convergence": conv or "unknown",
                      "disclose": runlog.disclosure(conv, run)}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
