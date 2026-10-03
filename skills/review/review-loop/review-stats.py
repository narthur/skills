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
import os
import sys

# Reuse runlog's store path and phase-merge rather than keeping a second copy of
# them here: two implementations of "read this append-only log" drift, and the
# one that drifts is the one nobody is looking at. A plain import works because
# Python puts the executed script's own directory at sys.path[0], and runlog.py
# sits beside this file.
import runlog

ALARM_THRESHOLD = 3
ALARM_WINDOW = 50


def load():
    """Runs oldest-first, so `runs[-N:]` is the most recent N."""
    return sorted(runlog.load().values(), key=lambda r: r.get("planned_at") or "")


def is_abandoned(run, current_session=None):
    """An open run that no live session owns.

    Nothing writes this outcome at the time it happens: the Stop hook fires at
    every turn boundary, so it cannot tell a run that is mid-flight from one that
    died, and guessing there would write a false outcome into the record. Reading
    is the moment the question is actually answerable — a plan with no finish,
    from a session that is not the one asking, was abandoned.
    """
    if run.get("outcome"):
        # Explicitly abandoned counts as abandoned wherever it is read; anything
        # else with an outcome is finished.
        return run["outcome"] == "abandoned"
    if not current_session:
        # Invoked from a plain shell with no session env: we cannot tell a dead
        # run from one in flight somewhere else, and guessing here would report
        # exactly the falsehood that deriving-on-read exists to avoid.
        return False
    # A row that never named a session is unknown, not dead — the same conclusion
    # this function already reaches for a reader that never named one. Guessing here
    # reported every headless run (session_id null) as abandoned, and three of those
    # in 50 tripped the alarm at Step 0 of every later run. runlog.unfinished()
    # handles the mirror case the same careful way.
    return bool(run.get("session_id")) and run["session_id"] != current_session


def dropped_gates(run):
    """Gates planned to run that did not report done."""
    planned = {g for g, v in (run.get("gates") or {}).items()
               if isinstance(v, dict) and v.get("planned") == "run"}
    executed = run.get("executed") or {}
    out = {}
    for g in planned:
        st = (executed.get(g) or {}).get("status") if isinstance(executed.get(g), dict) else None
        if st not in runlog.GATE_OK:
            out[g] = st or "unreported"
    return out


# A gate the run accounted for is a different signal from one it failed to complete, and
# the two have different fixes — which is what the alarm's own closing line has always
# said. Counting them together made the alarm report correct behaviour as failure: five
# reported misses of `record_reviewed` over 21 runs contained no real miss at all.
#
# NEITHER vocabulary is closed. `runlog.cmd_finish` requires a non-empty reason for every
# status but `done` and never validates the string, so any spelling can reach here. Two
# earlier attempts each enumerated one side and lost to the other: listing the deliberate
# words put `pending` and `deferred` in the failure bucket, and listing the failure words
# put `error`, `timeout`, `crashed` and even `FAILED` in the deliberate one — the same
# defect mirrored, and the second is the worse direction because it softens.
#
# So what settles it is the DEFAULT, not the list: an unrecognised status is far likelier
# to be a new failure or a bug than a new deliberate word, so anything unknown falls to
# the loud bucket, and the message names it. That is also how a genuinely new deliberate
# word gets noticed and added here on purpose rather than silently absorbed.
#
# Not fixed by widening runlog.GATE_OK, which is the right place for this distinction to
# NOT exist: derive_tier reads it to decide `partial`, and a run that did not complete a
# planned gate genuinely is partial. Widening it there would launder partial into full.
# Derived from the docs, not from memory: references/report-format.md:64 enumerates the
# measurement gate's outcomes as passed / waived / deferred / skipped / blocked, and
# references/measurement-gate.md:65 says a waiver PASSES the gate. `blocked` is
# deliberately absent — references/evidence-gate.md treats a blocked gate as a real
# problem, so it belongs in the loud bucket.
#
# Missing `waived` was the THIRD time this one decision went wrong: enumerate the
# deliberate words and a failure spelling softens; enumerate the failures and a deliberate
# one shouts; enumerate the deliberate words from memory and you miss one the prose
# already documents. The loud default is what keeps the third kind survivable — an
# omission here over-reports rather than hides, and the message names the status so the
# omission is visible rather than silent.
DECLINED_STATES = ("skipped", "pending", "deferred", "waived")


def _naming(seen):
    """The statuses behind a count, for the message — `unreported` adds nothing to read."""
    named = sorted(x for x in seen if x != "unreported")
    return f" ({', '.join(named)})" if named else ""


def cmd_alarm(runs):
    recent = runs[-ALARM_WINDOW:]
    here = os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("AO_SESSION_ID")
    dropped = collections.Counter()
    declined = collections.Counter()
    drop_why = collections.defaultdict(set)
    decline_why = collections.defaultdict(set)
    for run in recent:
        if is_abandoned(run, here):
            # One event, one counter. An abandoned run has every planned gate unreported
            # by construction, so also attributing it per gate turned a single
            # abandonment into nine gate failures — which is how three gates crossed the
            # threshold with no real miss between them. The abandonment is the actionable
            # signal and already has its own counter; `report` still shows per-gate detail.
            dropped["(run abandoned)"] += 1
            continue
        for g, st in dropped_gates(run).items():
            # str(): a non-string status is not rejected at write time either, and
            # formatting one into the message crashed the whole alarm with a TypeError —
            # taking down every gate's signal, not just the malformed one.
            st = str(st)
            if st in DECLINED_STATES:
                declined[g] += 1
                decline_why[g].add(st)
            else:
                dropped[g] += 1
                drop_why[g].add(st)

    hits = [(n, g, f"did not complete{_naming(drop_why[g])}")
            for g, n in dropped.items() if n >= ALARM_THRESHOLD]
    hits += [(n, g, f"was declined with a reason{_naming(decline_why[g])}")
             for g, n in declined.items() if n >= ALARM_THRESHOLD]
    # A gate that fails BOTH ways still needs raising. Thresholding the two buckets
    # independently alone would have taken a gate from 3 non-completions to raise to 5 —
    # two of each is four, and silent. The split exists to name the right fix, not to
    # make a gate that thrashes between them cheaper to ignore.
    reported = {g for _, g, _ in hits}
    for g in set(dropped) | set(declined):
        total = dropped[g] + declined[g]
        if g not in reported and total >= ALARM_THRESHOLD:
            hits.append((total, g, f"did not complete {dropped[g]}x and was declined "
                                   f"{declined[g]}x, in varying ways"))
    if not hits:
        return 0
    # Sorted across both buckets, because the printed order reads as a ranking and
    # concatenating two separately-sorted lists put a 3x drop above a 6x decline.
    hits.sort(key=lambda h: (-h[0], h[1]))
    print(f"review-loop alarm — over the last {len(recent)} runs:")
    for n, g, what in hits:
        print(f"  {g} {what} {n}x" if "varying ways" not in what else f"  {g} {what}")
    print("  Repeat count beats calendar: fix the gate or change the plan, don't log it again.")
    return 0


def cmd_report(runs, repo):
    if repo:
        runs = [r for r in runs if repo in (r.get("repo") or "")]
    if not runs:
        print("no runs recorded")
        return 0
    here = os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("AO_SESSION_ID")
    lost = [r for r in runs if is_abandoned(r, here)]
    # Both of runlog's SUBCOMMAND_STATES are bookkeeping, not review passes: `carried`
    # is a rebase moving an existing record onto a new sha, `skipped` is a change
    # judged beneath the loop. Each has an outcome, so each would otherwise count as
    # `finished` and inflate the one number here that reports review cadence — a
    # branch rebased ten times would read as ten more reviews than were run. Taken
    # from runlog rather than restated, so the two definitions cannot drift.
    book = [r for r in runs if r.get("outcome") in runlog.SUBCOMMAND_STATES]
    fin = [r for r in runs if r.get("outcome")
           and r["outcome"] not in runlog.SUBCOMMAND_STATES and not is_abandoned(r, here)]
    open_n = len(runs) - len(fin) - len(lost) - len(book)
    label = "open (unknown — run from the session that owns them)" if not here else "in flight (this session)"
    tail = "".join(f"  {name} ({what}, not a review): {n}"
                   for name, what, n in (
                       ("skipped", "judged beneath the loop",
                        sum(1 for r in book if r.get("outcome") == "skipped")),
                       ("carried", "rebase bookkeeping",
                        sum(1 for r in book if r.get("outcome") == "carried")))
                   if n)
    print(f"runs: {len(runs)}  finished: {len(fin)}  abandoned: {len(lost)}  {label}: {open_n}" + tail)

    def tally(label, key):
        c = collections.Counter(r.get(key) or "(unset)" for r in runs)
        print(f"\n{label}: " + "  ".join(f"{k}={v}" for k, v in c.most_common()))

    tally("outcome", "outcome")
    tally("tier floor", "tier_floor")
    tally("tier executed", "tier_executed")
    tally("session kind", "session_kind")
    tally("orchestrator model", "orchestrator_model")

    # Convergence and spend, derived from the cycle rows. This is the only place the
    # agent cap's number can be chosen with evidence rather than guessed: the default
    # is a guess until we know how often runs converge, exhaust the budget, or just
    # stop. Derived here via runlog rather than read from a field, for the same reason
    # push-check derives it — a self-reported outcome is what this record replaced.
    conv = collections.Counter(runlog.convergence(r) or "unknown" for r in fin)
    if conv:
        print("\nconvergence: " + "  ".join(f"{k}={v}" for k, v in conv.most_common()))

    # Agents is the cap's unit because it is derivable; tokens are the real cost.
    # Reporting both is what lets the proxy be checked against actual spend before the
    # cap moves to a token or weighted basis — the stated reason tokens are recorded.
    # Over `fin`, the same population as the denominator below. Summing cycles across ALL
    # runs while dividing by finished ones counted open, abandoned, carried and skipped runs
    # in the numerator only: a finished run of 4 agents beside an in-flight run of 20 reports
    # "mean agents/run: 24.0" where the honest figure is 4.0 — reproduced in this suite's own
    # fixture, not observed in the store, which has never recorded a 20-agent cycle. These are
    # the two numbers this block exists to let the cap be chosen from.
    cyc = [c for r in fin for c in runlog.cycles_of(r)]
    ag = sum(c.get("agents") or 0 for c in cyc)
    tok = sum(c.get("subagent_tokens") or 0 for c in cyc)
    if cyc:
        bits = [f"cycles: {len(cyc)}", f"agents: {ag}"]
        if len(fin):
            bits.append(f"mean agents/run: {ag / len(fin):.1f}")
        if tok and ag:
            bits.append(f"mean tokens/agent: {tok / ag:,.0f}")
        elif not tok:
            # Absence is the finding: the cap cannot move off its agent-count proxy
            # until something records what the agents actually cost.
            bits.append("tokens: none recorded")
        print("\n" + "  ".join(bits))

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
