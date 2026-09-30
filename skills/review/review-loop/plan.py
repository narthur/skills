#!/usr/bin/env python3
"""Compute the review plan — which gates run, which skip, and the tier floor.

Exists because the orchestrator carries ~430 lines of procedure while also doing
the review work, and the steps it drops are exactly the ones whose trigger is a
value in some script's output (PR #1359 dropped five of them silently).
Those triggers are computable, so they are computed here instead of remembered.

The agent never names a tier. This emits a FLOOR; the orchestrator may escalate
above it (recorded), never descend. Descent is what breaks iteration on the
skill, because no two runs then execute the same process.

The four inputs that are not computable are booleans, never prose — free text is
where improvisation re-enters wearing a manifest.

  context.sh > "$(git rev-parse --git-dir)/review-loop-context.json"
  plan.py --context "$(git rev-parse --git-dir)/review-loop-context.json" --model <orchestrator-model> \
      --logic yes --behavioral-goal yes --runtime-change yes --attacker-reachable no \
      [--spec-artifact yes] [--dry-run]

Prints the plan as JSON. Unless --dry-run, also writes the `plan` run record and
prints its run_id on the last line.
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

STRUCTURAL_LINES = 150  # Agent #7's "substantial diff" floor, per SKILL.md
BIG_FILE_LINES = 800


def run(cmd, timeout=15):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (OSError, subprocess.SubprocessError) as exc:
        return 1, "", str(exc)


def gate(planned, reason):
    return {"planned": planned, "reason": reason}


def threat_model_state():
    rc, out, _ = run([sys.executable, os.path.join(HERE, "threat-model.py")])
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def github_reachable():
    rc, out, _ = run(["git", "remote", "-v"])
    if rc != 0 or "github.com" not in out:
        return False, "no github remote"
    rc, _, _ = run(["gh", "auth", "status"], timeout=20)
    if rc != 0:
        # Seen repeatedly: the sandbox proxy denies api.github.com while git push works.
        return False, "gh not authenticated here (retry unsandboxed before accepting this)"
    return True, "gh authenticated, github remote present"


def biggest_changed_file(base):
    if not base:
        return 0
    rc, root, _ = run(["git", "rev-parse", "--show-toplevel"])
    if rc != 0:
        return 0
    # -z keeps paths literal: core.quotepath would otherwise hand back an escaped
    # name that matches nothing on disk, and each miss silently reads as 0 lines.
    rc, out, _ = run(["git", "diff", "--name-only", "-z", f"origin/{base}...HEAD"])
    if rc != 0:
        return 0
    biggest = 0
    for name in out.split("\0"):
        if not name:
            continue
        try:
            # Paths are repo-root-relative; cwd need not be the root.
            with open(os.path.join(root, name), "rb") as fh:
                biggest = max(biggest, sum(1 for _ in fh))
        except OSError:
            continue  # deleted by this diff — it has no size at HEAD
    return biggest


def build(ctx, a):
    changed = ctx.get("changed_lines") or 0
    base = ctx.get("base_branch")
    gates = {}

    # --- tier floor -----------------------------------------------------------
    fast_ok = bool(ctx.get("fast_path_eligible_by_size")) and not a.logic
    if fast_ok:
        tier = "fast"
        tier_reason = f"{changed} changed lines and no program logic touched"
    else:
        tier = "full"
        why = []
        if not ctx.get("fast_path_eligible_by_size"):
            why.append(f"{changed} changed lines (fast path is <30)")
        if a.logic:
            why.append("diff touches program logic")
        tier_reason = "; ".join(why) or "default"

    # --- always-on ------------------------------------------------------------
    gates["upstream_drift_check"] = gate("run", "cheap, no LLM")
    gates["learnings_capture"] = gate("run", "always")
    gates["pr_report"] = gate("run", "always — defer to pending-report file if no PR yet")
    gates["record_reviewed"] = gate("run", "on clean exit")

    # --- computable from context.sh ------------------------------------------
    due = bool(ctx.get("learnings_compaction_due"))
    gates["staleness_sweep"] = gate(
        "run" if due else "skip",
        f"{ctx.get('learnings_entries', 0)} learnings entries"
        + (" — at/over the 40 threshold" if due else " — under the 40 threshold"))

    # --- threat model ---------------------------------------------------------
    tm = threat_model_state()
    if tm is None:
        gates["threat_model"] = gate("run", "threat-model.py failed — run the update rather than assume clean")
    elif not tm.get("exists"):
        gates["threat_model"] = gate("run", "no threat model yet — bounded bootstrap")
    else:
        stale = tm.get("stale") or []
        if stale:
            gates["threat_model"] = gate("run", f"{len(stale)} stale claim(s) — each is a worklist item")
        elif a.attacker_reachable:
            gates["threat_model"] = gate("run", "diff touches attacker-reachable surface")
        else:
            gates["threat_model"] = gate("skip", "no stale claims and no attacker-reachable surface in the diff")

    gates["security_review"] = gate(
        "skip" if tier == "fast" else "run",
        "fast path folds the finder into the single reviewer" if tier == "fast" else "runs every cycle")

    # --- conditional agents ---------------------------------------------------
    if tier == "fast":
        for aid in ("agent_7_structural", "agent_8_observability", "agent_9_intent",
                    "agent_10_prior_feedback", "agent_11_spec"):
            gates[aid] = gate("skip", "fast path runs no conditional agents")
    else:
        # Only pay the per-file scan when the line count alone hasn't decided it.
        big_file = 0 if changed >= STRUCTURAL_LINES else biggest_changed_file(base)
        substantial = changed >= STRUCTURAL_LINES or big_file >= BIG_FILE_LINES
        gates["agent_7_structural"] = gate(
            "run" if substantial else "skip",
            f"{changed} changed lines"
            + (f", largest changed file {big_file} lines" if big_file else "")
            + ("" if substantial else f" — under both floors ({STRUCTURAL_LINES}/{BIG_FILE_LINES})"))
        gates["agent_8_observability"] = gate(
            "run" if substantial else "skip",
            "substantial diff — skip the observability half if the project logs nothing"
            if substantial else "not a substantial diff (#7's threshold)")
        gates["agent_9_intent"] = gate(
            "run" if a.behavioral_goal else "skip",
            "reviewable intent established at Step 4b" if a.behavioral_goal
            else "no statable behavioral goal — nothing to reconcile against")
        ok, why = github_reachable()
        gates["agent_10_prior_feedback"] = gate("run" if ok else "skip", why)
        gates["agent_11_spec"] = gate(
            "run" if a.spec_artifact else "skip",
            "written spec artifact captured verbatim at Step 4b" if a.spec_artifact
            else "no written spec artifact — never synthesise one from the diff")

    # --- post-loop gates ------------------------------------------------------
    gates["evidence_gate"] = gate(
        "run" if a.runtime_change else "skip",
        "runtime behavior changes" if a.runtime_change else "diff changes no runtime functionality")
    gates["measurement_gate"] = gate(
        "run" if a.runtime_change else "skip",
        "user-facing behavior may change — waive in the report if the repo cannot measure"
        if a.runtime_change else "no user-facing behavior change")

    return {
        "tier_floor": tier,
        "tier_reason": tier_reason,
        "changed_lines": changed,
        "base_branch": base,
        "inputs": {
            "logic": a.logic,
            "behavioral_goal": a.behavioral_goal,
            "runtime_behavior_change": a.runtime_change,
            "attacker_reachable": a.attacker_reachable,
            "spec_artifact": a.spec_artifact,
        },
        "gates": gates,
    }


def yesno(v):
    return v.lower() in ("yes", "y", "true", "1")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--context", help="context.sh JSON file (default: stdin)")
    p.add_argument("--model", required=True, help="the ORCHESTRATOR's model id — the only model that varies across runs")
    p.add_argument("--logic", type=yesno, required=True, metavar="yes|no",
                   help="does the diff change program logic?")
    p.add_argument("--behavioral-goal", type=yesno, required=True, metavar="yes|no",
                   help="is there a statable behavioral goal? (gates #9)")
    p.add_argument("--runtime-change", type=yesno, required=True, metavar="yes|no",
                   help="does runtime behavior change? (gates the evidence + measurement gates)")
    p.add_argument("--attacker-reachable", type=yesno, required=True, metavar="yes|no",
                   help="is any changed path attacker-reachable?")
    p.add_argument("--spec-artifact", type=yesno, default=False, metavar="yes|no",
                   help="did Step 4b capture a written spec artifact verbatim? (gates #11)")
    p.add_argument("--dry-run", action="store_true", help="print the plan without recording it")
    a = p.parse_args()

    if a.context:
        with open(a.context, encoding="utf-8") as fh:
            raw = fh.read()
    else:
        raw = sys.stdin.read()
    try:
        ctx = json.loads(raw)
    except ValueError as exc:
        sys.exit(f"plan: context is not valid JSON ({exc}) — run context.sh first")

    plan = build(ctx, a)
    print(json.dumps(plan, indent=2))

    # Repeat count beats calendar: surface a gate that keeps not completing at the
    # one moment the skill is already open, rather than waiting for a batch review.
    rc, alarm, _ = run([sys.executable, os.path.join(HERE, "review-stats.py"), "--alarm"], timeout=10)
    if rc == 0 and alarm:
        print("\n" + alarm, file=sys.stderr)
    if a.dry_run:
        return

    rc = subprocess.run([
        sys.executable, os.path.join(HERE, "runlog.py"), "plan",
        "--tier", plan["tier_floor"],
        "--model", a.model,
        "--base", plan["base_branch"] or "",
        "--changed-lines", str(plan["changed_lines"]),
        "--inputs", json.dumps(plan["inputs"]),
        "--gates", json.dumps(plan["gates"]),
    ])
    if rc.returncode:
        # The plan JSON is already on stdout and looks complete. Say plainly that it
        # was not recorded, or the orchestrator reads a successful-looking plan and
        # proceeds with no run_id and no Stop-hook net under it.
        print("plan: COMPUTED BUT NOT RECORDED — no run_id exists, the Stop hook will "
              "not track this run. Fix the error above and re-run plan.py before "
              "starting the review.", file=sys.stderr)
    sys.exit(rc.returncode)


if __name__ == "__main__":
    main()
