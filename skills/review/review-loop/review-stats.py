#!/usr/bin/env python3
"""Read the run record — what actually happens across review-loop runs.

A record with no consumer is the write-only-log failure already logged against
friction.md (three defects were one-line entries there and recurred anyway,
because nothing converted an entry into a fix). So there are two consumers:

  review-stats.py            ad-hoc, when you want to know
  review-stats.py --alarm    called by plan.py at Step 0, one line or silence

The alarm exists because repeat count beats calendar. A gate dropped three times
is a stronger signal than "it is time for a batch review", and Step 0 is the one
moment you are already in the skill and would act on it.
"""
import argparse
import collections
import importlib.util
import os
import sys

ALARM_THRESHOLD = 3
ALARM_WINDOW = 50

# Reuse runlog's store path and phase-merge rather than keeping a second copy of
# them here: two implementations of "read this append-only log" drift, and the
# one that drifts is the one nobody is looking at. Loaded by path because the
# filename has a hyphen-free sibling but this script does not sit on sys.path.
_spec = importlib.util.spec_from_file_location(
    "runlog", os.path.join(os.path.dirname(os.path.abspath(__file__)), "runlog.py"))
runlog = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(runlog)


def load():
    """Runs oldest-first, so `runs[-N:]` is the most recent N."""
    return sorted(runlog.load().values(), key=lambda r: r.get("planned_at") or "")


def abandoned(run, current_session=None):
    """An open run that no live session owns.

    Nothing writes this outcome at the time it happens: the Stop hook fires at
    every turn boundary, so it cannot tell a run that is mid-flight from one that
    died, and guessing there would write a false outcome into the record. Reading
    is the moment the question is actually answerable — a plan with no finish,
    from a session that is not the one asking, was abandoned.
    """
    if run.get("outcome"):
        return False
    return run.get("session_id") != current_session


def dropped_gates(run):
    """Gates planned to run that did not report done."""
    planned = {g for g, v in (run.get("gates") or {}).items()
               if isinstance(v, dict) and v.get("planned") == "run"}
    executed = run.get("executed") or {}
    out = {}
    for g in planned:
        st = (executed.get(g) or {}).get("status") if isinstance(executed.get(g), dict) else None
        if st != "done":
            out[g] = st or "unreported"
    return out


def cmd_alarm(runs):
    recent = runs[-ALARM_WINDOW:]
    here = os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("AO_SESSION_ID")
    counts = collections.Counter()
    for run in recent:
        if run.get("outcome") == "abandoned" or abandoned(run, here):
            counts["(run abandoned)"] += 1
        for g in dropped_gates(run):
            counts[g] += 1
    hits = [(g, n) for g, n in counts.most_common() if n >= ALARM_THRESHOLD]
    if not hits:
        return 0
    print(f"review-loop alarm — over the last {len(recent)} runs:")
    for g, n in hits:
        print(f"  {g} did not complete {n}x")
    print("  Repeat count beats calendar: fix the gate or change the plan, don't log it again.")
    return 0


def cmd_report(runs, repo):
    if repo:
        runs = [r for r in runs if repo in (r.get("repo") or "")]
    if not runs:
        print("no runs recorded")
        return 0
    here = os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("AO_SESSION_ID")
    fin = [r for r in runs if r.get("outcome")]
    lost = [r for r in runs if abandoned(r, here)]
    print(f"runs: {len(runs)}  finished: {len(fin)}  "
          f"abandoned: {len(lost)}  in flight (this session): {len(runs) - len(fin) - len(lost)}")

    def tally(label, key):
        c = collections.Counter(r.get(key) or "(unset)" for r in runs)
        print(f"\n{label}: " + "  ".join(f"{k}={v}" for k, v in c.most_common()))

    tally("outcome", "outcome")
    tally("tier floor", "tier_floor")
    tally("tier executed", "tier_executed")
    tally("session kind", "session_kind")
    tally("orchestrator model", "orchestrator_model")

    drops = collections.Counter()
    by_model = collections.defaultdict(collections.Counter)
    by_kind = collections.defaultdict(collections.Counter)
    for r in runs:
        for g in dropped_gates(r):
            drops[g] += 1
            by_model[r.get("orchestrator_model") or "(unset)"][g] += 1
            by_kind[r.get("session_kind") or "(unset)"][g] += 1
    if drops:
        print("\ngates planned but not completed:")
        for g, n in drops.most_common():
            print(f"  {n:3d}  {g}")
        print("\n  by orchestrator model:")
        for m, c in sorted(by_model.items()):
            print(f"    {m}: " + ", ".join(f"{g}×{n}" for g, n in c.most_common(4)))
        print("  by session kind:")
        for k, c in sorted(by_kind.items()):
            print(f"    {k}: " + ", ".join(f"{g}×{n}" for g, n in c.most_common(4)))

    esc = collections.Counter(
        e.get("gate") or "(unnamed)"
        for r in runs for e in (r.get("escalations") or []) if isinstance(e, dict))
    if esc:
        print("\nescalations above the computed floor (thresholds may be too loose):")
        for g, n in esc.most_common():
            print(f"  {n:3d}  {g}")

    asks = sum(r.get("unresolved_asks") or 0 for r in runs)
    if asks:
        print(f"\nunresolved ask-bucket items across all runs: {asks}")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--alarm", action="store_true", help="print only repeat-offender gates; silent when clean")
    p.add_argument("--repo", help="filter to runs whose repo path contains this")
    a = p.parse_args()
    runs = load()
    sys.exit(cmd_alarm(runs) if a.alarm else cmd_report(runs, a.repo))


if __name__ == "__main__":
    main()
