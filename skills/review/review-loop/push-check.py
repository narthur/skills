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
import contextlib
import importlib
import io
import json
import os
import subprocess
import sys

# Plain import: the executed script's own directory is sys.path[0], and runlog is the
# single definition of how convergence is derived. Restating the derivation here is how
# the two would drift — the mistake this whole field exists to correct.
import runlog

BROKEN_OUTCOMES = ("test-failure", "blocked", "abandoned")
# The marker pr-report.py writes at the top of every report body. Matching it is how this
# script checks that the report actually reached a reader.
REPORT_MARKER = "<!-- review-loop:run={} -->"
PENDING_FMT = "info/review-loop-pending-report.{}.md"


def sh(*args, repo="."):
    """Run a command in `repo`. Swallows OSError so a missing `gh` reads as "cannot tell"."""
    try:
        p = subprocess.run(args, capture_output=True, text=True, check=False,
                           timeout=20, cwd=repo)
    except (OSError, subprocess.SubprocessError):
        return 1, "", "not available"
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def report_fingerprint(run):
    """The strings a real rendered report must contain for THIS run, from the record.

    The marker alone was not enough: `printf '<!-- review-loop:run=X -->' > <pending>` is 38
    bytes and satisfied the gate, making it CHEAPER to forge than the `disclosed --where
    "trust me"` row it replaced. Requiring the run line too means the numbers have to agree
    with the cycle rows, which cannot be produced without rendering from the record — the
    point being that this is a property of the artifact, not a claim about it.
    """
    cy = runlog.cycles_of(run)
    spent = sum(c.get("agents") or 0 for c in cy)
    return ["## review-loop", f"{len(cy)} cycle(s) · {spent} agent(s)"]


def report_landed(run_id, run, repo="."):
    """Has this run's rendered report reached somewhere a reader will see it?

    No "cannot tell" result: no gh and no git both read as "not landed", which fails closed,
    and pr-report guarantees the body lands in one of the two places checked — a PR comment
    or this run's pending file — including when the post fails. So "neither" means pr-report
    did not run, which is the one thing this gate exists to catch.
    """
    needles = [REPORT_MARKER.format(run_id)] + report_fingerprint(run)
    rc, out, _ = sh("gh", "pr", "view", "--json", "comments",
                    "-q", ".comments[].body", repo=repo)
    if rc == 0 and all(n in out for n in needles):
        return True
    rc, gitdir, _ = sh("git", "rev-parse", "--path-format=absolute", "--git-common-dir", repo=repo)
    if rc == 0 and gitdir:
        try:
            with open(os.path.join(gitdir, PENDING_FMT.format(run_id)), encoding="utf-8") as fh:
                body = fh.read()
            return all(n in body for n in needles)
        except OSError:
            pass
    return False


def decide(convergence, gate_state, unresolved_skip, branch, default_branch, upstream_exists,
           outcome=None, unreported=None):
    """First failing check wins — mirrors Step 14 'When NOT to auto-push'.

    `convergence` is "converged", "capped", "halted", or None/"unknown" when the run
    recorded no cycles. Only "converged" needs no disclosure; everything else — None
    included, so omitting the cycle rows can never buy a silent push — pushes with one.

    `outcome` and `unreported` are read from the record and the filesystem. They exist
    because moving
    convergence into the record and then making convergence non-blocking left nothing
    that blocks derived from the record at all — every remaining blocker was an
    orchestrator-supplied flag, which is the shape `--clean-exit` was retired for.
    """
    # "Stopped looking" is a disclosure; "it is broken" is a block. Removing --clean-exit
    # deleted the only channel by which a Step 9 test failure reached this decision, and
    # the replacement was never added: a run recorded test-failure with a failed gate was
    # permitted with the reason "converged, evidence gate ok".
    if outcome in BROKEN_OUTCOMES:
        return False, f"run recorded {outcome} — broken, not merely unfinished"
    # The report is the entire consideration for which a non-converged run is allowed to
    # push, and prose instructions to post it are the ones that get skipped — which is why
    # pr-report.py is a script at all. Required on EVERY terminal exit, not just the
    # non-converged ones: the incident that motivated this redesign (buzz #376) was a
    # CLEAN exit on a fresh branch whose summary never reached the PR.
    if unreported:
        return False, unreported
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
    # Through sh(), which swallows OSError and bounds the call. As a raw subprocess.run this
    # was the only crash path in the file: it is evaluated as an argument to decide(), so an
    # empty PATH produced a traceback and an empty stdout where Step 14 expects JSON.
    return sh("git", "rev-parse", "--abbrev-ref", "@{upstream}", repo=repo)[0] == 0


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
    # A recorded broken outcome blocks, and outranks a converged review: the tree is the
    # problem, not the review's completeness.
    for bad in ("test-failure", "blocked", "abandoned"):
        push, reason = decide("converged", "passed", False, *ok, outcome=bad)
        assert push is False, bad
        assert bad in reason, reason
    assert decide("converged", "passed", False, *ok, outcome="clean")[0] is True
    # An owed-but-missing report blocks, and says what to run.
    push, reason = decide("capped", "passed", False, *ok, unreported="report has not reached the PR")
    assert push is False and "report has not reached" in reason
    # And it blocks a CONVERGED run too: the incident that motivated this was a clean exit
    # whose summary never reached the PR, so gating only the non-converged runs misses it.
    assert decide("converged", "passed", False, *ok, unreported="x")[0] is False
    # main() end to end against a real store — the claim "convergence is READ FROM THE
    # RECORD" had no test, so defaulting conv to "converged" passed this selftest while
    # emitting a silent unconverged push.
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        os.environ["REVIEW_LOOP_RUNS"] = os.path.join(td, "runs.jsonl")
        importlib.reload(runlog)
        # No --run-id is refused outright. It used to be optional, which made BOTH
        # record-derived blockers invisible while a bogus id was correctly caught — so the
        # cheapest wrong spelling was the one that passed.
        try:
            main(["--branch", "feat/x", "--default-branch", "main", "--gate-state", "passed"])
        except SystemExit as exc:
            assert "run-id is required" in str(exc), exc
        else:
            raise AssertionError("push-check must refuse to run without --run-id")
        # A run-id absent from the store is "unknown", never converged.
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            main(["--run-id", "nosuchrun", "--branch", "feat/x",
                  "--default-branch", "main", "--gate-state", "passed"])
        got = json.loads(out.getvalue())
        assert got["convergence"] == "unknown", got        # absent from the store either

        # main()'s wiring of the two record-derived blockers, not just decide()'s handling
        # of them: replacing `outcome=run.get("outcome"), unreported=unreported` with
        # None, None used to pass every suite, which is the same "the channel was never
        # wired" shape that removing --clean-exit left behind.
        import runlog as rl
        gates = {"t": {"planned": "run", "reason": "2 stale claims"}}
        subprocess.run(["git", "init", "-q", "."], cwd=td, check=False)
        rid = "pcselftest01"
        rl.STORE = os.environ["REVIEW_LOOP_RUNS"]
        rl.append({"run_id": rid, "phase": "plan", "repo": td, "gates": gates,
                   "agent_cap": 40, "planned_at": rl.now()})
        rl.append({"run_id": rid, "phase": "cycle", "n": 1, "applied": 3, "agents": 5})
        rl.append({"run_id": rid, "phase": "finish", "outcome": "test-failure",
                   "finished_at": rl.now(), "executed": {"t": {"status": "done"}}})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            main(["--run-id", rid, "--branch", "feat/x", "--default-branch", "main",
                  "--gate-state", "passed", "--repo", td])
        got = json.loads(out.getvalue())
        assert got["push"] is False, got
        assert "test-failure" in got["reason"], got      # the record's outcome reached decide()

        # And the report check: no report anywhere -> refused, naming pr-report.
        rid2 = "pcselftest02"
        rl.append({"run_id": rid2, "phase": "plan", "repo": td, "gates": gates,
                   "agent_cap": 8, "planned_at": rl.now()})
        rl.append({"run_id": rid2, "phase": "cycle", "n": 1, "applied": 3, "agents": 9})
        rl.append({"run_id": rid2, "phase": "finish", "outcome": "cycle-limit",
                   "finished_at": rl.now(), "executed": {"t": {"status": "done"}}})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            main(["--run-id", rid2, "--branch", "feat/x", "--default-branch", "main",
                  "--gate-state", "passed", "--repo", td])
        got = json.loads(out.getvalue())
        assert got["push"] is False and "pr-report" in got["reason"], got
        # A marker-only file must NOT satisfy the gate: at 38 bytes that was cheaper to
        # forge than the `disclosed --where "trust me"` row this replaced.
        gitdir = os.path.join(td, ".git")
        os.makedirs(os.path.join(gitdir, "info"), exist_ok=True)
        pend = os.path.join(gitdir, PENDING_FMT.format(rid2))
        with open(pend, "w", encoding="utf-8") as fh:
            fh.write(REPORT_MARKER.format(rid2) + "\n\nthe report\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            main(["--run-id", rid2, "--branch", "feat/x", "--default-branch", "main",
                  "--gate-state", "passed", "--repo", td])
        assert json.loads(out.getvalue())["push"] is False, "a marker alone satisfied the gate"
        # The real thing: marker plus the run line, whose numbers come from the cycle rows.
        run2 = runlog.load(limit=None)[rid2]
        with open(pend, "w", encoding="utf-8") as fh:
            fh.write(REPORT_MARKER.format(rid2) + "\n\n"
                     + "\n".join(report_fingerprint(run2)) + "\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            main(["--run-id", rid2, "--branch", "feat/x", "--default-branch", "main",
                  "--gate-state", "passed", "--repo", td])
        got = json.loads(out.getvalue())
        assert got["push"] is True, got                  # artifact present -> permitted
        assert got["disclose"], got                      # and still carries the disclosure

        # The tier does not reach this gate. Five places said it did — SKILL.md,
        # references/finish.md, derive_tier's docstring, and two git-dir records — and a
        # sixth, the comment under that docstring, made the neighbouring wrong claim that
        # the LABEL reads it (it is keyed on convergence). All six survived because none
        # was stated as an assertion: prose about what some OTHER module reads has no
        # failing test when it rots. So state it here. Re-finishing the same run as
        # `partial` must change nothing about the decision; if someone makes push-check
        # read the tier, this fails and the docs saying it doesn't are stale.
        # Only tier_executed differs from the row above — the outcome stays
        # `cycle-limit`. Writing `clean` here too passed, but for a confounded
        # reason: it changed two fields decide() is given, and both of those
        # outcomes happen to be non-blocking, so the test would have proved
        # nothing about the tier had the outcome handling been what differed.
        rl.append({"run_id": rid2, "phase": "finish", "outcome": "cycle-limit",
                   "finished_at": rl.now(), "tier_executed": "partial",
                   "executed": {"t": {"status": "done"}}})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            main(["--run-id", rid2, "--branch", "feat/x", "--default-branch", "main",
                  "--gate-state", "passed", "--repo", td])
        assert json.loads(out.getvalue()) == got, "tier_executed changed the push decision"
    print("ok")


def main(argv):
    ap = argparse.ArgumentParser()
    # Required, not optional. Both record-derived blockers were computed only when it was
    # present, so omitting it turned off the owed-report check AND the broken-outcome check
    # while a bogus id was correctly caught — the cheapest wrong spelling was the one that
    # passed.
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
    if not a.run_id:
        sys.exit("push-check: --run-id is required — without it the record's outcome and the "
                 "report check are both invisible, and the run pushes on nothing")
    # No --run-id means no record to read, which is not the same as converged. Fail
    # closed the way a missing cycle row does: push, but disclose that nothing is known.
    run, conv = {}, None
    if a.run_id:
        run = runlog.load(limit=None).get(a.run_id) or {}
        conv = runlog.convergence(run)
    unreported = None
    if not report_landed(a.run_id, run, a.repo):
        unreported = ("this run's report has not reached the PR or the pending-report file — "
                      "run pr-report.py --post first")
    push, reason = decide(conv, a.gate_state, a.unresolved_skip,
                          a.branch, a.default_branch, _upstream_exists(a.repo),
                          outcome=run.get("outcome"), unreported=unreported)
    print(json.dumps({"push": push, "reason": reason,
                      "convergence": conv or "unknown",
                      "disclose": runlog.disclosure(conv, run)}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
