#!/usr/bin/env python3
"""Two-phase run record for review-loop.

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

  runlog.py plan    --tier <floor> --model <m> [--base <b>] [--changed-lines <n>]
                    [--semantic-lines <n>] [--sizing-excluded <t>] [--tier-reason <t>]
                    [--agent-cap <n>] [--inputs <json>] [--gates <json>] [--head <sha>]
                    [--run-id <id>]
  runlog.py finish  --run-id <id> --outcome <o> [--tier <t>] [--executed <json>]
                    [--escalations <json>] [--agents <json>] [--findings <json>] [--asks <n>]
                    [--allow-unaccounted]
  runlog.py skipped --reason <r> [--model <m>]     one complete row, tier=skipped
  runlog.py carried --from <sha> --to <sha> --how reviewed|skipped
  runlog.py check   [--head <sha>] [--session <id>] [--force]   exit 1 on an unfinished run
  runlog.py nudge   --run-id <id>
  runlog.py abandon --run-id <id> --missing <text>
  runlog.py cycle   --run-id <id> --n <k> --applied <n> --agents <n> [--asked <n>]
                    [--defect-findings <n>] [--comment-findings <n>] [--analysis-changed]
                    [--tokens <n>]
  runlog.py convergence --run-id <id>              prints it; exit 0 only if converged
  runlog.py disclosed --run-id <id> --where <w>    the disclosure reached a reader
  runlog.py show    --run-id <id>
"""
import argparse
import json
import os
import subprocess
import sys
import uuid
from collections import deque
from datetime import datetime, timezone

STORE = os.path.expanduser(
    os.environ.get("REVIEW_LOOP_RUNS") or "~/.claude/review-loop/runs.jsonl")


def now():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def git(*args, cwd=None):
    try:
        out = subprocess.run(("git",) + args, capture_output=True, text=True, cwd=cwd, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def repo_id():
    """Stable identity for a repo across worktrees: the common dir's path."""
    common = git("rev-parse", "--path-format=absolute", "--git-common-dir")
    if not common:
        return os.getcwd()
    # .../foo/.git -> .../foo ; a bare repo keeps its own path.
    return os.path.dirname(common) if os.path.basename(common) == ".git" else common


def session_kind():
    """Which kind of session is driving this run.

    One of the axes the record exists to answer ("which session kind drops gates"),
    so a misclassification here quietly corrupts that answer. The tty test alone
    gets it wrong: an interactive Claude Code session runs its commands with stdin
    detached, so every interactive run logged as headless. CLAUDE_CODE_SESSION_ATTENDED
    is the harness's own answer to the question and outranks the guess.
    """
    if os.environ.get("AO_SESSION_ID"):
        return "ao-worker"
    if os.environ.get("CLAUDE_REVIEW_LOOP_SUBAGENT"):
        return "subagent"
    attended = os.environ.get("CLAUDE_CODE_SESSION_ATTENDED")
    if attended is not None:
        return "interactive" if attended not in ("", "0", "false") else "headless"
    if not sys.stdin.isatty() and not sys.stderr.isatty():
        return "headless"
    return "interactive"


def append(rec):
    # Checked here, not at each caller: `plan` persists a free-text reason per gate
    # and `abandon` persists `--missing`, and both are directly invocable. Guarding
    # only `finish` left two of the three write paths open to exactly the reason
    # this store exists to refuse.
    reject_banned(reasons_in(rec))
    os.makedirs(os.path.dirname(STORE), exist_ok=True)
    line = json.dumps(rec, separators=(",", ":"), sort_keys=True) + "\n"
    # A single write() to a regular file opened O_APPEND does not interleave with
    # other writers on the local filesystems this store lives on (APFS, ext4),
    # which is what lets concurrent worktree sessions share one file without a
    # lock. Note this is NOT the POSIX PIPE_BUF guarantee — that covers pipes, not
    # regular files — and it does not hold over NFS. Records are also unbounded in
    # size, so there is no PIPE_BUF-style safety margin to appeal to. load()
    # therefore tolerates a torn line rather than assuming one can't happen.
    fd = os.open(STORE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, line.encode())
    finally:
        os.close(fd)


# The store is append-only and never pruned, and `check` reads it from the Stop
# hook on every turn boundary of every session on the machine. Only recent runs
# can affect any answer — an open run is recent by construction, and the alarm
# looks at the last 50 — so read a bounded tail rather than the whole history.
# Bounding the read (not the file) keeps the append-only concurrency property:
# compacting would mean a rewrite, which is what clobbered the shared run dir.
# Overridable so the tail boundary itself is testable — a bound you cannot cross
# in a test is a bound nothing checks.
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
    Measured: a run that spent 40 agents across three rows counted 20 against its cap,
    because the restart's `n=1` (5 agents) replaced the original `n=1` (20 agents).

    It exists as a function rather than inline so that `convergence()`, `disclosure()`
    and pr-report cannot read the list three different ways — which is exactly what had
    happened: disclosure() read the raw list and the other two read this one, so one PR
    comment reported "CAPPED at 11 of 8 agents" above a table showing 8.
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
    cap = run.get("agent_cap")
    spent = sum(c.get("agents") or 0 for c in cy)
    if cap and spent >= cap:
        return "capped"
    # Stopped with work outstanding and budget left: an operator interrupt, a test
    # failure, or a run that simply stopped. The Bands run was this and had no value
    # that described it.
    return "halted"


def disclosure(conv, run):
    """The line a PR must carry when the loop did not converge. None if it did.

    This is the whole point of letting a capped run push: the branch ships, and the PR
    says how far to trust it. A silent capped push would be strictly worse than the
    stall it replaces.
    """
    if conv == "converged":
        return None
    # cycles_of, not the raw list: reading it raw made this disagree with the derivation
    # it exists to explain. Measured, one rendered comment said "CAPPED at 11 of 8
    # agents: the last cycle applied 0 fix(es)" above a table whose last cycle applied 5.
    cy = cycles_of(run or {})
    last = cy[-1] if cy else {}
    spent = sum(c.get("agents") or 0 for c in cy)
    cap = (run or {}).get("agent_cap")
    if conv is None:
        return ("Review completeness UNKNOWN: this run recorded no cycles, so nothing can say "
                "whether the loop still had findings when it stopped. Treat as unreviewed.")
    head = {"capped": f"Review CAPPED at {spent} of {cap} agents",
            "halted": f"Review HALTED after {len(cy)} cycle(s), {spent} agents"}[conv]
    return (f"{head}: the last cycle applied {last.get('applied', '?')} fix(es)"
            + (f" and left {last['asked']} finding(s) awaiting a decision" if last.get("asked") else "")
            + (" and the deterministic pass still had unresolved findings" if last.get("analysis_changed") else "")
            + ". The loop had not stopped finding things — another cycle would likely find more.")

# All four states convergence() can report, "unknown" standing for None. Exported so
# consumers key off this rather than restating the vocabulary: pr-report.py's labels used
# to list all four independently while this tuple listed three, which is the divergence
# the export exists to prevent.
CONVERGENCE = ("converged", "capped", "halted", "unknown")
# A ceiling, not a target. Set above where the hard cases actually settle: the record has
# one run that converged within two cycles, against three that were still finding real
# defects at three to four passes — so a ceiling that binds on every hard case is a stall
# with extra steps. (An earlier version of this comment claimed "two runs converged in
# 1-2 cycles" and "two did not, at 3 and 4 passes"; the record supports neither count.)
# Overridable per run via --agent-cap.
DEFAULT_AGENT_CAP = 40


def parse_json_arg(raw, what):
    if raw is None:
        return None
    try:
        return json.loads(raw)
    except ValueError as exc:
        sys.exit(f"runlog: --{what} is not valid JSON: {exc}")


# "It has precedent in the repo" is an invalid justification for reduced review,
# not a weak one: bugs pre-exist, copying a pattern propagates them, and the copy
# is the cheapest moment to catch one. Size and no-logic are measurable facts
# about a diff; precedent is an inference from existing code to its correctness.
BANNED_REASON = (
    "precedent", "already exists in the repo", "matches an existing pattern",
    "matches existing pattern", "same pattern as", "pattern copy", "pattern-copy",
    "copied from existing", "consistent with existing code", "follows the existing pattern",
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


def reasons_in(rec):
    """Every free-text reason a record carries, with a label for the error."""
    out = []
    for gate, v in (rec.get("gates") or {}).items():
        # Complement rather than a list of values, matching the executed loop below.
        # cmd_plan's PLANNED check makes this currently equivalent to `== "skip"`, so it
        # is consistency and not load-bearing — if that check is ever relaxed, this one
        # does not have to be found and changed too.
        if isinstance(v, dict) and v.get("planned") != "run":
            out.append((f"gate {gate!r} as {v.get('planned')}", v.get("reason")))
    for gate, v in (rec.get("executed") or {}).items():
        # The exact complement of the test cmd_finish uses to DEMAND a reason, so every
        # status that owes one gets it vetted. Listing statuses here instead went stale
        # the moment `n/a` was added: cmd_finish demanded an n/a reason, nothing checked
        # it, and `n/a` became the one status whose reason could cite precedent. Worse,
        # it is the strongest claim in the vocabulary ("this gate cannot apply here")
        # and so the one most worth checking.
        if isinstance(v, dict) and v.get("status") != "done":
            out.append((f"gate {gate!r} as {v.get('status')}", v.get("reason")))
    for e in rec.get("escalations") or []:
        if isinstance(e, dict):
            out.append((f"escalation on {e.get('gate')!r}", e.get("reason")))
    for key, label in (("abandoned_missing", "this abandonment"), ("skip_reason", "this skip"),
                       # sizing_excluded justifies counting fewer lines, and fewer lines
                       # buy a cheaper tier and skipped agents. It was the one free-text
                       # field licensing reduced review that no check ever read, so it was
                       # also the one place a precedent argument could still be written.
                       ("sizing_excluded", "this sizing exclusion"),
                       ("tier_reason", "this tier")):
        if rec.get(key):
            out.append((label, rec[key]))
    return out


def reject_banned(reasons):
    for where, text in reasons:
        low = (text or "").lower()
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


PLANNED = ("run", "skip")


def cmd_plan(a):
    # A non-positive cap makes `capped` unreachable, so a genuinely out-of-budget run
    # reports `halted` instead — the softer "we just stopped" label. A negative one makes
    # every unconverged run report `capped`, which blames the budget for a loop that quit.
    # Neither should be expressible.
    if a.agent_cap is not None and a.agent_cap <= 0:
        sys.exit(f"runlog: --agent-cap must be positive (got {a.agent_cap}) — a cap of zero "
                 "or less cannot bind, it only changes which label a stall gets")
    gates = parse_json_arg(a.gates, "gates") or {}
    # planned_gates demands an account only for "run", so a gate whose planned value is
    # neither run nor skip was dropped silently AND escaped the reason ban. A plan is the
    # artifact the whole record is derived from; refuse a malformed one here rather than
    # teaching every consumer a third value it has never seen.
    bad_plan = sorted(g for g, v in gates.items()
                      if not isinstance(v, dict) or v.get("planned") not in PLANNED)
    if bad_plan:
        sys.exit(
            "runlog: refusing to plan — these gates are not "
            f"{{\"planned\": \"run\"|\"skip\", \"reason\": ...}}:\n  {', '.join(bad_plan)}"
        )
    unexplained = sorted(g for g, v in gates.items() if not (v.get("reason") or "").strip())
    if unexplained:
        sys.exit(
            "runlog: refusing to plan — these gates carry no reason:\n  "
            f"{', '.join(unexplained)}\nA gate's reason is what a later run is "
            "measured against; an unexplained plan cannot be iterated on."
        )
    rec = {
        "run_id": a.run_id or uuid.uuid4().hex[:12],
        "phase": "plan",
        "planned_at": now(),
        "repo": repo_id(),
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
        "head": a.head or git("rev-parse", "HEAD"),
        "base": a.base,
        "orchestrator_model": a.model,
        "session_kind": a.session_kind or session_kind(),
        # Linked worktrees share a git-common-dir, so repo alone would let one
        # session's open run block another's Stop — the same collision that
        # clobbered review-loop-run/ twice.
        "session_id": os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("AO_SESSION_ID"),
        "tier_floor": a.tier,
        "inputs": parse_json_arg(a.inputs, "inputs") or {},
        "gates": gates,
        "changed_lines": a.changed_lines,
        "agent_cap": a.agent_cap,
        "semantic_lines": a.semantic_lines,
        "sizing_excluded": a.sizing_excluded,
        # Recorded, not just printed: plan.py computed this and dropped it on the way to
        # the record, so the one field saying WHY a tier was chosen was null on every run.
        "tier_reason": a.tier_reason,
    }
    append(rec)
    print(rec["run_id"])


def plan_of(run_id):
    """This run's plan record. Uncapped: see load()."""
    return load(limit=None).get(run_id) or {}


def planned_gates(plan):
    """Gates the plan said to run."""
    return {g for g, v in (plan.get("gates") or {}).items()
            if isinstance(v, dict) and v.get("planned") == "run"}


def unaccounted(planned, executed, escalations):
    """Gates the plan said to run that the finish neither ran nor escalated.

    This is the invariant the whole record exists for. Without it, `finish` records
    whatever the orchestrator chose to mention, and a dropped gate is once again
    only as visible as the orchestrator's honesty — which is the failure this was
    built to stop being reliant on.
    """
    accounted = set(executed) | {e.get("gate") for e in escalations if isinstance(e, dict)}
    return sorted(planned - accounted)


# Every state the record can hold, in one place, so a consumer can discover the
# vocabulary here rather than by reading each writer's body.
OUTCOMES = ("clean", "cycle-limit", "test-failure", "blocked", "abandoned", "skipped", "carried")
TIERS = ("skipped", "carried", "fast", "full", "partial")
# Outcomes written by their own subcommands, never claimed as an outcome at
# `finish` — a run cannot award itself either one. `--outcome` below subtracts both,
# so the vocabulary above stays the single definition rather than a stale copy of
# it. `--tier skipped` stays valid: a run may report that it executed the skipped
# tier. Only `carried` is off-limits as a tier. review-stats.py also reads this to
# keep both out of its cadence count.
SUBCOMMAND_STATES = ("skipped", "carried")
# A gate that reports `n/a` was handled — the gate does not apply to this repo — so
# it is success, not a drop. review-stats.py reads this rather than restating it:
# when it had its own `status == "done"` test, every `n/a` counted as a dropped gate
# and the Step 0 alarm fired permanently on gates nobody could fix, which teaches a
# reader to scroll past the alarms that are right.
GATE_OK = ("done", "n/a")
TIER_RANK = {"skipped": 0, "carried": 0, "fast": 1, "full": 2, "partial": 2}


def derive_tier(claimed, executed, agents, planned=None, floor=None):
    """`partial` is a fact about the run, not a label the caller picks.

    Any planned agent that failed, or any gate that did not complete, makes the run
    partial — the PR label and the push gate both read it that way, so letting a
    caller write `full` over it launders the run.
    """
    # Only gates the plan said to run count. An entry for a gate the plan already
    # marked skip is redundant, not a failure, and shouldn't drag the tier down.
    broken = [g for g, v in executed.items()
              if isinstance(v, dict) and v.get("status") not in GATE_OK
              and (planned is None or g in planned)]
    # "done" and "ok" are the same claim. Gates say `done`, so a caller writing the
    # agent roster reaches for `done` too — and counted every successful agent as a
    # failure, forcing `partial` on a run where nothing failed. An over-reported
    # `partial` is still a false record, and it teaches the next reader that partial
    # is normal. Accept both words rather than legislating one.
    broken += [x.get("id", "?") for x in agents
               if isinstance(x, dict) and x.get("status") not in ("ok", "done")]
    if broken and claimed != "partial":
        print(f"runlog: recording tier `partial`, not {claimed!r} — did not complete: "
              f"{', '.join(broken)}", file=sys.stderr)
        return "partial"
    # The floor exists so a run cannot be reviewed less than the rule says. That
    # is enforced per-gate above, but the recorded tier is what the label and the
    # aggregation report, so a claim below the floor would describe the run
    # falsely even with every gate accounted for.
    if floor and TIER_RANK.get(claimed, 0) < TIER_RANK.get(floor, 0):
        sys.exit(
            f"runlog: refusing to record tier {claimed!r} — the plan computed a floor of "
            f"{floor!r}. You may escalate above the floor, never below it. Record "
            f"{floor!r} (or `partial` if something did not complete)."
        )
    return claimed


def cmd_cycle(a):
    """Record one completed cycle. This is what convergence is derived from.

    Append-only and one row per cycle, so the sequence survives: pass 4 of run
    b480b45cc65d left no trace anywhere in that record, because cycles appeared only in
    free-form fields the orchestrator rewrote each time — `agents`, `findings`, and gate
    reasons in prose.
    """
    if not plan_of(a.run_id):
        sys.exit(f"runlog: no plan for run {a.run_id!r} — record the plan first")
    # A cycle row appended after `finish` silently rewrites a convergence that has
    # already been disclosed on a PR and already cleared a push. Measured: a finished
    # `halted` run flipped to `converged` with disclose null and push true after one
    # `cycle --applied 0 --agents 0`. That is the assertion path the derivation was
    # built to remove, respelled — `--clean-exit` by another name. cmd_abandon already
    # refuses on the same grounds; this is the same guard.
    prior = load(limit=None).get(a.run_id) or {}
    if prior.get("finished_at") or prior.get("outcome"):
        sys.exit(f"runlog: run {a.run_id!r} is already finished — a cycle row appended now "
                 "would change a convergence that has already been reported. Start a new run.")
    for name, val in (("n", a.n), ("applied", a.applied), ("asked", a.asked),
                      ("agents", a.agents), ("tokens", a.tokens)):
        if val is not None and val < 0:
            sys.exit(f"runlog: --{name} cannot be negative (got {val}) — a negative count "
                     "pulls cumulative spend back under the cap")
    append({
        "run_id": a.run_id,
        "phase": "cycle",
        "n": a.n,
        "closed_at": now(),
        "applied": a.applied,
        "asked": a.asked,
        # Separated on purpose: a third of the Bands findings were "this comment claims
        # more than the code does". Legitimate work, but not defect-finding, and
        # counting them together made the run look more productive than it was.
        "defect_findings": a.defect_findings,
        "comment_findings": a.comment_findings,
        "analysis_changed": bool(a.analysis_changed),
        "agents": a.agents,
        # Recorded, never enforced. Agent count is the cap's unit because it is
        # derivable; tokens are the real cost. Logging both lets the proxy be checked
        # against actual spend before the cap moves to a token or weighted basis.
        "subagent_tokens": a.tokens,
    })
    print(f"runlog: cycle {a.n} of {a.run_id} ({a.applied} applied, {a.agents} agents)",
          file=sys.stderr)
    return 0


def cmd_convergence(a):
    """Print the derived convergence, for shell consumers. Exit 0 only if converged."""
    run = load(limit=None).get(a.run_id)
    if not run:
        print("unknown", file=sys.stderr)
        return 2
    c = convergence(run)
    print(c or "unknown")
    return 0 if c == "converged" else 1


def cmd_finish(a):
    executed = parse_json_arg(a.executed, "executed") or {}
    escalations = parse_json_arg(a.escalations, "escalations") or []
    plan = plan_of(a.run_id)  # one read, shared by everything derived below
    planned = planned_gates(plan)
    # A non-dict value is malformed, not an account. `{"gate": "done"}` — the natural
    # typo for the documented `{"gate": {"status": "done"}}` — slipped past every
    # isinstance guard here and in derive_tier, so it recorded `full` while
    # review-stats read the gate as dropped: the row and the reader disagreeing about
    # the same run. Refusing it is one clause; widening three guards is not.
    unexplained = sorted(g for g, v in executed.items()
                         if not isinstance(v, dict)
                         # n/a still needs its why — "there is no PR" is the reason.
                         or (v.get("status") != "done"
                             and not (v.get("reason") or "").strip()))
    if unexplained:
        sys.exit(
            "runlog: refusing to finish — these gates carry no usable account (a status "
            'other than "done" with no reason, or not a {"status":..,"reason":..} object '
            f"at all):\n  {', '.join(unexplained)}\n"
            "A status says what happened; the reason is the part anyone reading this "
            "later actually needs. Give each one a measurable reason."
        )
    missing = unaccounted(planned, executed, escalations)
    if missing and not a.allow_unaccounted:
        sys.exit(
            "runlog: refusing to finish — the plan said to run these gates and the "
            f"finish accounts for none of them:\n  {', '.join(missing)}\n"
            "Give each one an `executed` entry (status done/skipped/failed, with a "
            "reason for anything but done) or record an escalation. If they genuinely "
            "went unrun and you are recording that fact, pass --allow-unaccounted and "
            "the run is marked partial."
        )
    agents = parse_json_arg(a.agents, "agents") or []
    if missing:
        for g in missing:
            executed[g] = {"status": "failed", "reason": "unaccounted at finish"}
    rec = {
        "run_id": a.run_id,
        "phase": "finish",
        "finished_at": now(),
        "outcome": a.outcome,
        "tier_executed": derive_tier(a.tier, executed, agents, planned,
                                     plan.get("tier_floor")),
        "executed": executed,
        "escalations": escalations,
        "agents": agents,
        "findings": parse_json_arg(a.findings, "findings") or {},
        "unresolved_asks": a.asks,
        "head_at_finish": git("rev-parse", "HEAD"),
    }
    append(rec)
    # Say it at finish, where it can still be fixed, rather than letting the push gate
    # refuse later on a run that may well have converged.
    conv = convergence(load(limit=None).get(a.run_id) or {})
    if conv is None:
        print("runlog: WARNING — no cycle rows for this run, so convergence is unknown, "
              "which every consumer reads as 'did not converge'. Record each cycle with "
              "`runlog.py cycle`.", file=sys.stderr)
    elif a.outcome == "clean" and conv != "converged":
        # The derivation was added to displace the self-report; the self-report stayed.
        # Run b480b45cc65d recorded `clean` for a run its own author says did not
        # converge, and that exact record is still writable — so name the disagreement
        # rather than printing both values side by side as if they agreed.
        print(f"runlog: WARNING — outcome 'clean' but the cycle rows derive {conv!r}. "
              "The derivation is what the PR and the push gate read; `clean` here is a "
              "self-report that contradicts it. Record the missing cycle or fix the "
              "outcome.", file=sys.stderr)
    print(f"runlog: finished {a.run_id} ({a.outcome}; convergence: {conv or 'unknown'})")


def cmd_disclosed(a):
    """Record that this run's disclosure actually reached a reader.

    A capped or halted run is allowed to push on the condition that the PR says how far
    it was reviewed. That condition was prose, and prose instructions to post the summary
    are the ones that get skipped — the whole reason pr-report.py exists as a script. So
    push-check refuses a non-converged push until this row exists for the current head,
    which is what turns "not optional" into something a later reader can audit.

    Written by pr-report.py, in both of its branches: posting to a PR and writing the
    pending file both count, because on a fresh branch the push gate forces
    loop-then-push-then-PR and there is no PR to post to yet. `where` says which.
    """
    if not plan_of(a.run_id):
        sys.exit(f"runlog: no plan for run {a.run_id!r}")
    append({
        "run_id": a.run_id,
        "phase": "disclosed",
        "disclosed_at": now(),
        "disclosed_where": a.where,
        # Pinned to the commit, not just the run: a disclosure describing an earlier tip
        # says nothing about what is being pushed now.
        "disclosed_head": a.head or git("rev-parse", "HEAD"),
    })
    print(f"runlog: disclosure recorded for {a.run_id} ({a.where})", file=sys.stderr)
    return 0


def disclosure_pending(run, head):
    """Why this run may not push yet, or None. Shared so push-check cannot restate it."""
    conv = convergence(run)
    if disclosure(conv, run) is None:
        return None
    if not run.get("disclosed_head"):
        return (f"review derived {conv or 'unknown'}, which obliges the PR to say so, and no "
                "disclosure has been recorded — run pr-report.py first")
    if head and run["disclosed_head"] != head:
        return (f"the recorded disclosure describes {run['disclosed_head'][:12]}, not the "
                f"commit being pushed ({head[:12]}) — re-run pr-report.py")
    return None


def cmd_carried(a):
    """Record that a review record moved to a rewritten commit.

    A rebase or amend rewrites shas, which invalidates a perfectly good review
    record. Only a patch-identical rewrite can be carried; a rebase that changed
    anything still owes a review. carry-review.sh's header holds the measurement of
    how often that is — restating it here is how the two drifted apart. The carry
    itself is provenance and belongs in the audit trail:
    reviewed-at-one-sha-and-carried is not the same claim as reviewed-here, and a
    later reader should be able to tell which they are looking at.
    """
    append({
        "run_id": uuid.uuid4().hex[:12],
        "phase": "finish",
        "finished_at": now(),
        "repo": repo_id(),
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
        "head": a.to,
        "head_at_finish": a.to,
        "session_kind": session_kind(),
        "outcome": "carried",
        "tier_executed": "carried",
        "carried_from": a.frm,
        "carried_how": a.how,
        "carried_by": a.by,
        "executed": {},
    })
    print(f"runlog: recorded {a.how} record carried {a.frm[:12]} -> {a.to[:12]}")


def cmd_skipped(a):
    """One complete row for a change judged beneath the loop.

    record-skipped.sh used to be a second store the gate had to ask a second
    question of. Routing it here leaves the gate one question — is there a
    complete row for this sha — and puts the reason through the same precedent
    check every other stated reason gets.
    """
    # append() guards each write, but this is a two-write operation: a refusal on
    # the second would leave the first behind as a phantom open run for the Stop
    # hook to nag about. Check once, up front, so a refused skip writes nothing.
    reject_banned([("this skip", a.reason)])
    rid = uuid.uuid4().hex[:12]
    base = {
        "run_id": rid, "repo": repo_id(), "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
        "head": git("rev-parse", "HEAD"), "orchestrator_model": a.model,
        "session_kind": session_kind(),
        "session_id": os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("AO_SESSION_ID"),
    }
    append(dict(base, phase="plan", planned_at=now(), tier_floor="skipped", gates={}))
    append({"run_id": rid, "phase": "finish", "finished_at": now(),
            "outcome": "skipped", "tier_executed": "skipped",
            "executed": {}, "skip_reason": a.reason,
            "head_at_finish": base["head"]})
    print(rid)


def cmd_nudge(a):
    """Record that the Stop hook already prompted about this run.

    Stop fires at every turn boundary, not only when a session ends, so a run
    that is merely mid-flight trips it. Without this marker the hook would nag
    every turn of a long review — and its bounded retry would then write
    `abandoned` over a run that was still going, corrupting the record it exists
    to keep honest. Abandonment is derived on read instead (review-stats.py):
    an open run from a session that is no longer current was abandoned, and no
    hook has to guess that mid-flight.
    """
    append({"run_id": a.run_id, "phase": "nudge", "nudged_at": now()})


def cmd_abandon(a):
    # load() merges records by run_id field-wise, so appending this over an
    # existing finish would leave `outcome: abandoned` sitting next to that run's
    # `executed: {all done}`. A finish is terminal; say so rather than corrupt it.
    existing = load(limit=None).get(a.run_id) or {}
    if existing.get("outcome"):
        sys.exit(f"runlog: {a.run_id} already finished as {existing['outcome']!r} — not overwriting")
    append({
        "run_id": a.run_id,
        "phase": "finish",
        "finished_at": now(),
        "outcome": "abandoned",
        "abandoned_missing": a.missing,
        "head_at_finish": git("rev-parse", "HEAD"),
    })
    print(f"runlog: marked {a.run_id} abandoned — {a.missing}")


def unfinished(repo, head=None, session=None):
    """Planned runs in this repo with no finish record, newest first.

    A `session` narrows to runs this session started. Runs recorded without a
    session id still match — they predate the field or came from a script, and
    dropping them would silently stop guarding them.
    """
    out = []
    for run in load().values():
        if run.get("repo") != repo or run.get("phase") == "finish":
            continue
        if head and run.get("head") != head:
            continue
        if session and run.get("session_id") and run["session_id"] != session:
            continue
        out.append(run)
    return sorted(out, key=lambda r: r.get("planned_at", ""), reverse=True)


def cmd_check(a):
    repo = repo_id()
    session = a.session or os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("AO_SESSION_ID")
    mine = [r for r in unfinished(repo, a.head, session)
            if not a.run_id or r["run_id"] == a.run_id]
    if not mine:
        print("runlog: no unfinished run")
        return 0
    # Report every unfinished run, not just the newest: a session that re-planned
    # after an error leaves an earlier one open, and reporting only mine[0] made it
    # invisible for the rest of the session's life.
    fresh = [r for r in mine if r.get("phase") != "nudge" or a.force]
    if not fresh:
        print("runlog: unfinished run already nudged")
        return 0
    out = [{
        "run_id": r["run_id"],
        "head": r.get("head"),
        "tier_floor": r.get("tier_floor"),
        "planned_gates": sorted(planned_gates(r)),
    } for r in fresh]
    # run_id/planned_gates stay at the top level for the single-run case the Stop
    # hook reads; `also_open` carries the rest.
    payload = dict(out[0])
    if len(out) > 1:
        payload["also_open"] = out[1:]
    print(json.dumps(payload, indent=1))
    return 1


def cmd_show(a):
    run = load(limit=None).get(a.run_id)
    if not run:
        sys.exit(f"runlog: no run {a.run_id}")
    print(json.dumps(run, indent=1, sort_keys=True))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("plan")
    sp.add_argument("--run-id")
    sp.add_argument("--head")
    sp.add_argument("--base")
    sp.add_argument("--tier", required=True, choices=["fast", "full", "skipped"])
    sp.add_argument("--model", required=True, help="the ORCHESTRATOR's model; review agents are pinned separately")
    sp.add_argument("--session-kind", choices=["interactive", "ao-worker", "headless", "subagent"])
    sp.add_argument("--inputs", help='JSON: {"logic":bool,"behavioral_goal":bool,"runtime_behavior_change":bool,"attacker_reachable":bool,"spec_artifact":bool}')
    sp.add_argument("--gates", help='JSON: {"<gate>":{"planned":"run"|"skip","reason":"..."}}')
    sp.add_argument("--changed-lines", type=int, help="raw added+deleted lines")
    # The record must hold what the sizing DECISION was made on, not just the raw
    # count. Without these, `semantic_lines` was computed, used for every threshold,
    # printed in the plan JSON — and dropped before the record, so a reader could not
    # check whether a cheaper review was bought by a defensible exclusion. A real run
    # (b480b45cc65d) recorded `semantic_lines: None` while its own gate reason cited
    # "1377 lines of review surface".
    # The cap bounds COST, not completeness — those were conflated when max_cycles was
    # the only thing stopping the loop. Cumulative agent invocations, because cycle
    # count stopped being a cost unit the moment fan-out width became variable: one
    # cycle may be 30 agents over 50 files and the next a single agent on a few lines.
    sp.add_argument("--tier-reason", help="why the plan landed on this floor (vetted like every reason)")
    sp.add_argument("--agent-cap", type=int, default=DEFAULT_AGENT_CAP,
                    help=f"cumulative agent budget for the run (default {DEFAULT_AGENT_CAP}); "
                         "hitting it records `capped`, which permits a push WITH disclosure")
    sp.add_argument("--semantic-lines", type=int,
                    help="raw minus whitespace-only, lockfiles and declared-generated files")
    sp.add_argument("--sizing-excluded", help="what was dropped from the raw count, and how much")
    sp.set_defaults(func=cmd_plan)

    sf = sub.add_parser("finish")
    sf.add_argument("--run-id", required=True)
    sf.add_argument("--outcome", required=True,
                    choices=[o for o in OUTCOMES if o not in SUBCOMMAND_STATES],
                    help="`skipped` and `carried` are also recorded outcomes, but their own "
                         "subcommands write them; a finishing run cannot claim either")
    sf.add_argument("--tier", choices=[t for t in TIERS if t != "carried"])
    sf.add_argument("--executed", help='JSON: {"<gate>":{"status":"done"|"skipped"|"failed","reason":"..."}}')
    sf.add_argument("--escalations", help='JSON list of {"gate":..,"reason":..}')
    sf.add_argument("--agents",
                    help='JSON list of {"id":..,"model":..,"status":"done"|"ok"|"failed",'
                         '"findings":N} — every entry needs an explicit done/ok; '
                         'anything else, including a missing status, makes the run partial')
    sf.add_argument("--findings", help='JSON: {"auto_fix":N,"asked":N,"skipped":N}')
    sf.add_argument("--asks", type=int, default=0, help="unresolved ask-bucket items")
    sf.add_argument("--allow-unaccounted", action="store_true",
                    help="record planned gates that went unrun, marking the run partial")
    sf.set_defaults(func=cmd_finish)

    sc = sub.add_parser("cycle", help="record one completed cycle (convergence is derived from these)")
    sc.add_argument("--run-id", required=True)
    sc.add_argument("--n", type=int, required=True, help="cycle number, 1-based")
    sc.add_argument("--applied", type=int, required=True, help="fixes applied this cycle")
    sc.add_argument("--asked", type=int, default=0, help="ask-bucket items put to the user")
    sc.add_argument("--defect-findings", type=int, default=0)
    sc.add_argument("--comment-findings", type=int, default=0,
                    help="'this comment claims more than the code does' — counted apart from defects")
    sc.add_argument("--analysis-changed", action="store_true",
                    help="the Step 4a deterministic pass changed files or left unresolved findings")
    sc.add_argument("--agents", type=int, required=True, help="agents spawned this cycle")
    sc.add_argument("--tokens", type=int, help="observed subagent tokens, recorded not enforced")
    sc.set_defaults(func=cmd_cycle)

    sv = sub.add_parser("convergence", help="print the DERIVED convergence; exit 0 only if converged")
    sd = sub.add_parser("disclosed", help="record that the disclosure reached a PR or the pending file")
    sd.add_argument("--run-id", required=True)
    sd.add_argument("--where", required=True, help="where it landed, e.g. a PR url or the pending path")
    sd.add_argument("--head", help="the commit it describes (default: HEAD)")
    sd.set_defaults(func=cmd_disclosed)

    sv.add_argument("--run-id", required=True)
    sv.set_defaults(func=cmd_convergence)

    sy = sub.add_parser("carried")
    sy.add_argument("--from", dest="frm", required=True, help="the rewritten-away sha")
    sy.add_argument("--to", required=True, dest="to", help="the new sha the record now covers")
    sy.add_argument("--how", required=True, choices=["reviewed", "skipped"])
    sy.add_argument("--by", default="patch-id", help="what established the two are the same content")
    sy.set_defaults(func=cmd_carried)

    sk = sub.add_parser("skipped")
    sk.add_argument("--reason", required=True)
    sk.add_argument("--model", default="(none)")
    sk.set_defaults(func=cmd_skipped)

    sn = sub.add_parser("nudge")
    sn.add_argument("--run-id", required=True)
    sn.set_defaults(func=cmd_nudge)

    sa = sub.add_parser("abandon")
    sa.add_argument("--run-id", required=True)
    sa.add_argument("--missing", required=True)
    sa.set_defaults(func=cmd_abandon)

    sc = sub.add_parser("check")
    sc.add_argument("--head")
    sc.add_argument("--run-id")
    sc.add_argument("--session", help="only runs this session started (default: $CLAUDE_CODE_SESSION_ID)")
    sc.add_argument("--force", action="store_true", help="report an unfinished run even if already nudged")
    sc.set_defaults(func=cmd_check)

    ss = sub.add_parser("show")
    ss.add_argument("--run-id", required=True)
    ss.set_defaults(func=cmd_show)

    a = p.parse_args()
    sys.exit(a.func(a) or 0)


if __name__ == "__main__":
    main()
