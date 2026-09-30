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
                    [--inputs <json>] [--gates <json>] [--head <sha>] [--run-id <id>]
  runlog.py finish  --run-id <id> --outcome <o> [--tier <t>] [--executed <json>]
                    [--escalations <json>] [--agents <json>] [--findings <json>] [--asks <n>]
                    [--allow-unaccounted]
  runlog.py skipped --reason <r> [--model <m>]     one complete row, tier=skipped
  runlog.py carried --from <sha> --to <sha> --how reviewed|skipped
  runlog.py check   [--head <sha>] [--session <id>] [--force]   exit 1 on an unfinished run
  runlog.py nudge   --run-id <id>
  runlog.py abandon --run-id <id> --missing <text>
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
        out = subprocess.run(("git",) + args, capture_output=True, text=True, cwd=cwd, timeout=10)
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
                runs.setdefault(rid, {}).update(rec)
    except FileNotFoundError:
        pass
    return runs


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
        if isinstance(v, dict) and v.get("planned") == "skip":
            out.append((f"gate {gate!r} as skip", v.get("reason")))
    for gate, v in (rec.get("executed") or {}).items():
        if isinstance(v, dict) and v.get("status") in ("skipped", "failed"):
            out.append((f"gate {gate!r} as {v.get('status')}", v.get("reason")))
    for e in rec.get("escalations") or []:
        if isinstance(e, dict):
            out.append((f"escalation on {e.get('gate')!r}", e.get("reason")))
    for key, label in (("abandoned_missing", "this abandonment"), ("skip_reason", "this skip")):
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


def cmd_plan(a):
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
        "gates": parse_json_arg(a.gates, "gates") or {},
        "changed_lines": a.changed_lines,
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


TIER_RANK = {"skipped": 0, "fast": 1, "full": 2, "partial": 2}


def derive_tier(claimed, executed, agents, planned=None, floor=None):
    """`partial` is a fact about the run, not a label the caller picks.

    Any planned agent that failed, or any gate that did not complete, makes the run
    partial — the PR label and the push gate both read it that way, so letting a
    caller write `full` over it launders the run.
    """
    # Only gates the plan said to run count. An entry for a gate the plan already
    # marked skip is redundant, not a failure, and shouldn't drag the tier down.
    broken = [g for g, v in executed.items()
              if isinstance(v, dict) and v.get("status") not in ("done", "n/a")
              and (planned is None or g in planned)]
    broken += [x.get("id", "?") for x in agents
               if isinstance(x, dict) and x.get("status") not in ("ok", None)]
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


def cmd_finish(a):
    executed = parse_json_arg(a.executed, "executed") or {}
    escalations = parse_json_arg(a.escalations, "escalations") or []
    plan = plan_of(a.run_id)  # one read, shared by everything derived below
    planned = planned_gates(plan)
    unexplained = sorted(g for g, v in executed.items()
                         if isinstance(v, dict) and v.get("status") != "done"
                         # n/a still needs its why — "there is no PR" is the reason.
                         and not (v.get("reason") or "").strip())
    if unexplained:
        sys.exit(
            "runlog: refusing to finish — these gates are recorded as not done with no "
            f"reason:\n  {', '.join(unexplained)}\n"
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
    print(f"runlog: finished {a.run_id} ({a.outcome})")


def cmd_carried(a):
    """Record that a review record moved to a rewritten commit.

    A rebase or amend rewrites shas, which invalidates a perfectly good review
    record — 8 rows in skipped-shas exist only to say "the loop reviewed this exact
    content, then a rebase renamed it". Carrying the record forward removes that
    friction, but the carry itself is provenance and belongs in the audit trail:
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


def cmd_skipped(a):  # noqa: D401
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
    sp.add_argument("--changed-lines", type=int)
    sp.set_defaults(func=cmd_plan)

    sf = sub.add_parser("finish")
    sf.add_argument("--run-id", required=True)
    sf.add_argument("--outcome", required=True,
                    choices=["clean", "cycle-limit", "test-failure", "blocked", "abandoned"])
    sf.add_argument("--tier", choices=["fast", "full", "partial", "skipped"])
    sf.add_argument("--executed", help='JSON: {"<gate>":{"status":"done"|"skipped"|"failed","reason":"..."}}')
    sf.add_argument("--escalations", help='JSON list of {"gate":..,"reason":..}')
    sf.add_argument("--agents", help='JSON list of {"id":..,"model":..,"status":..,"findings":N}')
    sf.add_argument("--findings", help='JSON: {"auto_fix":N,"asked":N,"skipped":N}')
    sf.add_argument("--asks", type=int, default=0, help="unresolved ask-bucket items")
    sf.add_argument("--allow-unaccounted", action="store_true",
                    help="record planned gates that went unrun, marking the run partial")
    sf.set_defaults(func=cmd_finish)

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
