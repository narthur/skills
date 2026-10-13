#!/usr/bin/env python3
"""The run record's vocabulary and reader, for review-loop's Python scripts.

Every run writes a `plan` record at Step 0 and a `finish` record at Step 14.
A plan with no finish is a visibly abandoned run — today that state is
indistinguishable from never having invoked the skill, which is how PR #1359
dropped five gated steps without anyone noticing.

Store: ~/.claude/review-loop/runs.jsonl, append-only, one JSON object per line.
Append-only on purpose: concurrent AO worktree sessions write this same file. A
different shared path under the git common dir (`info/review-loop-run/`) was
rewritten rather than appended and got clobbered twice under exactly that
concurrency pattern; appending avoids repeating it here. Readers merge phases by
run_id.

The writer is `~/.local/bin/looper record`, a port of this file's former command
line with the same rows, refusals and exit statuses, and `looper stats` replaced
review-stats.py, this file's last reader of the store. What stays here is what
is still imported: the precedent ban (learn.py), the agent cap (plan.py), and the
store path, phase-merge, derived convergence and the outcome and gate
vocabularies, which looper's parity tests run as their oracle. Those tests hold
looper's copies of the constants equal to these, so a change here is a change to
both.
"""
import json
import os
import sys
from collections import deque

STORE = os.path.expanduser(
    os.environ.get("REVIEW_LOOP_RUNS") or "~/.claude/review-loop/runs.jsonl")


# The store is append-only and never pruned, and the Step 0 alarm (review-stats.py's then,
# `looper stats --alarm` now, which parses this same variable the same way) reads it at
# Step 0 of every run. Only recent runs can affect any answer — an open run is recent
# by construction, and the alarm looks at the last 50 — so read a bounded tail rather
# than the whole history. Bounding the read (not the file) keeps the append-only
# concurrency property: compacting would mean a rewrite, which is what clobbered the
# shared run dir. Overridable so the tail boundary itself is testable — a bound you
# cannot cross in a test is a bound nothing checks.
try:
    TAIL_LINES = max(1, int(os.environ.get("REVIEW_LOOP_TAIL") or 4000))
except ValueError:
    TAIL_LINES = 4000  # a fat-fingered override must not break every invocation


def load(limit=TAIL_LINES):
    """Merge phase records into one dict per run_id, newest last.

    `limit=None` reads the whole store. Use it for anything that must find one
    specific run: a correctness check that silently sees no plan because the
    record scrolled past the tail is worse than a slow one.
    """
    runs = {}
    try:
        with open(STORE, encoding="utf-8") as fh:
            for line in (fh if limit is None else deque(fh, maxlen=limit)):
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue  # a torn line never invalidates the rest of the store
                rid = rec.get("run_id")
                if not rid:
                    continue
                run = runs.setdefault(rid, {})
                # Cycle rows ACCUMULATE; every other phase merges. A run has one plan
                # and one finish, so `.update()` is right for those — but it would make
                # each cycle clobber the last, leaving only the final one and destroying
                # the sequence convergence is derived from.
                if rec.get("phase") == "cycle":
                    run.setdefault("cycles", []).append(rec)
                else:
                    run.update(rec)
    except FileNotFoundError:
        pass
    return runs


def cycles_of(run):
    """Every cycle this run recorded, in the order they were recorded.

    One row per cycle that happened, no deduplication. This used to dedupe by `n`, last
    write winning, on the theory that a corrected row sits after the one it corrects —
    but nothing in the skill ever corrects a cycle row: loop step j2 writes once per
    cycle, and the only thing that revisits an `n` is the Step 13 restart, which resets
    the counter to 1. So the dedupe served a corrector that does not exist while
    silently deleting the first pass of every restart from every derived answer.
    Reproduced against the pre-fix code with rows n=1/20 agents, n=2/15, n=1/5: the cap
    counted 20 of the 40 spent, because the restart's `n=1` replaced the original.

    It exists as a function rather than inline so that its readers cannot read the list
    different ways — which is exactly what had happened: the retired disclosure() read the
    raw list while convergence() and the retired pr-report.py read this one, so a rendered
    report said "CAPPED at 11 of 8 agents" above a table showing 8. (Reproduced in a fixture,
    not seen on a real PR — the live record has only ever held one cycle row, and blurring
    "reproduced" into "observed" is how an invented measurement got committed here twice.)
    """
    return list(run.get("cycles") or [])


def convergence(run):
    """Why the loop stopped: ran out of findings, out of budget, or neither.

    Derived, never accepted. `push-check.py` used to take `--clean-exit` as a flag, so
    the one safety question — was this finished being reviewed — was answered by the
    orchestrator asserting it. Run b480b45cc65d recorded outcome `clean` for a run its
    own author reported as not converged, which is exactly what that allows.

    Returns None when there are no cycle rows: unknown, not converged. Every consumer
    must treat None as "did not converge", so omitting the rows can never buy a push.
    """
    cy = cycles_of(run)
    if not cy:
        return None
    last = cy[-1]
    # Asks recorded at finish are outstanding work even when no cycle row carries them, so
    # this precedes the converged test rather than following it — placed after, the converged
    # branch short-circuited it and the hole stayed open. The omission path: `cycle --applied
    # 0` with no --asked, then `finish --asks 7`, derived converged with disclose null while
    # seven findings sat unresolved and the PR said nothing was left to apply.
    if (run.get("unresolved_asks") or 0) > 0:
        return "halted"
    # Converged means the loop stopped with nothing left to do — all three halves. The
    # deterministic pass changing files is as much unfinished work as a non-empty
    # auto-fix bucket, and so is the ask bucket: a cycle that routed every finding to
    # the user and resolved none of them has not run out of findings, it has run out of
    # things it may do unattended. Measured before this: cycle(applied=0, asked=7)
    # derived `converged`, disclosure() returned None, push-check permitted the push
    # with no disclosure, and the PR read "converged — nothing left to apply".
    if (last.get("applied") == 0 and not last.get("asked")
            and not last.get("analysis_changed")):
        return "converged"
    # Asks recorded at finish count as outstanding work even when no cycle row carries them.
    # Without this the omission path stayed open: `cycle --applied 0` with no --asked, then
    # `finish --asks 7`, derived converged with disclose null while seven findings sat
    # unresolved with the user and the PR said the review found nothing left to apply.
    cap = run.get("agent_cap")
    spent = sum(c.get("agents") or 0 for c in cy)
    if cap and spent >= cap:
        return "capped"
    # Stopped with work outstanding and budget left: an operator interrupt, a test
    # failure, or a run that simply stopped. The Bands run was this and had no value
    # that described it.
    return "halted"


# A ceiling, not a target: set above where the hard cases settle, because a ceiling that
# binds on every hard case is a stall with extra steps. The counts that used to be quoted
# here are deliberately gone — they were restated by hand, went stale every time the record
# grew, and were wrong twice and disputed twice. `looper stats` derives them from the
# record (`convergence:` and `mean agents/run`), which is where to look before changing this
# number. Overridable per run via --agent-cap.
DEFAULT_AGENT_CAP = 40


# "It has precedent in the repo" is an invalid justification for reduced review,
# not a weak one: bugs pre-exist, copying a pattern propagates them, and the copy
# is the cheapest moment to catch one. Size and no-logic are measurable facts
# about a diff; precedent is an inference from existing code to its correctness.
BANNED_REASON = (
    "precedent", "already exists in the repo", "matches an existing pattern",
    "matches existing pattern", "same pattern as", "pattern copy", "pattern-copy",
    "copied from existing", "consistent with existing code", "follows the existing pattern",
    # Caught by its own new width-reason test: the list had "matches an existing pattern"
    # and "follows the existing pattern" but not this phrasing, so it was accepted.
    "consistent with existing pattern",
    "established pattern in this repo",
    "how the rest of the codebase",
    "how the rest of this codebase",
    "it's the convention here",
    "the convention in this repo",
    "identical to what",
    "same as what",
    "already done this way",
    "done this way elsewhere",
    "mirrors the existing",
)


def reject_banned(reasons):
    for where, text in reasons:
        # Whitespace-normalised, not just lowercased. Matching raw text let three of five
        # phrasings through: "matches  an   existing pattern", the same phrase broken by a
        # newline, and the same with a tab. A newline mid-phrase is not an evasion attempt,
        # it is what writing a reason long enough to wrap produces — so the substring check
        # was failing on the ordinary case, not only the adversarial one.
        low = " ".join((text or "").lower().split())
        for phrase in BANNED_REASON:
            if phrase in low:
                sys.exit(
                    f"runlog: refusing to record {where} — its reason cites precedent "
                    f"({phrase!r}).\n"
                    "Existing code being similar is not evidence it is correct; a copied "
                    "pattern carries its bugs, and the copy is the cheapest place to catch "
                    "them. State a measurable reason (size, no logic touched, no runtime "
                    "change) or run the gate."
                )


# Every state the record can hold, in one place, so a consumer can discover the
# vocabulary here rather than by reading each writer's body.
OUTCOMES = ("clean", "cycle-limit", "test-failure", "blocked", "abandoned", "skipped", "carried")
TIERS = ("skipped", "carried", "fast", "full", "partial")
# Outcomes written by their own subcommands, never claimed as an outcome at
# `finish` — a run cannot award itself either one. `looper record finish` subtracts
# both from OUTCOMES for its `--outcome`. `--tier skipped` stays valid: a run may
# report that it executed the skipped tier. Only `carried` is off-limits as a tier.
# `looper stats` keeps both out of its cadence count too, with its own copy.
SUBCOMMAND_STATES = ("skipped", "carried")
# A gate that reports `n/a` was handled — the gate does not apply to this repo — so
# it is success, not a drop. review-stats.py read this rather than restating it, and
# `looper stats` carries the same answer: when the alarm had its own `status == "done"`
# test, every `n/a` counted as a dropped gate and the Step 0 alarm fired permanently on
# gates nobody could fix, which teaches a reader to scroll past the alarms that are right.
GATE_OK = ("done", "n/a")
# Two different questions were being asked of one tuple. "Did the gate complete?" decides
# the tier; "should it be silent?" decides whether the alarm shows it. A waiver PASSES the
# gate (references/measurement-gate.md:65), so it must not force `partial` — but three runs
# waiving the same gate is precisely the signal the alarm exists to raise, so it must not go
# quiet either. Adding `waived` to GATE_OK would have done both at once and made its entry
# in the alarm's declined states (looper stats' DeclinedStates) dead code, hiding a repeated
# waiver completely.
# `passed` was briefly added here too and taken back out. It is report-line PROSE for a gate
# line (references/report-format.md:64), not a word in the `--executed` vocabulary, which is
# done|skipped|failed|n/a — a passing gate already has `done`. Accounting for it made the two
# instruments contradict each other on one record: the tier read `full` while the alarm read
# `measurement_gate did not complete (passed) 3x`, because `passed` is in neither GATE_OK nor
# looper stats' DeclinedStates. Two instruments disagreeing is worse than one being loud. Anything NOT
# listed here still forces partial and is still reported with its own name, which is the loud
# default three separate omissions have now argued for, and it is the right handler for a
# status nobody should be writing.
#
# GATE_OK, this tuple and TIER_RANK decide the tier `looper record finish` derives; nothing in
# this directory reads them any more. They stay because looper's TestWriteConstantsMatchThePython
# holds its copies equal to these, which keeps the tier's definition visible beside GATE_OK.
GATE_ACCOUNTED = GATE_OK + ("waived",)
TIER_RANK = {"skipped": 0, "carried": 0, "fast": 1, "full": 2, "partial": 2}


if __name__ == "__main__":
    print("runlog: the command line moved to `~/.local/bin/looper record`; "
          "runlog.py is a library now", file=sys.stderr)
    sys.exit(2)
