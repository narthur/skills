#!/usr/bin/env python3
"""Render and publish the review disclosure for a run, from the record.

The Step 14 summary is the single most-dropped step in this skill — it is in the
friction log, and the Bands run's own report had to be volunteered by its author
because nothing produced it. Prose instructions to "post the summary" get skipped; a
script that reads the record cannot skip a gate, cannot misstate convergence, and
cannot quietly leave out the fourth cycle.

Split on purpose, mirroring the skill's deterministic/agent division:

  * FACTS come from the run record — convergence, the disclosure, every gate with its
    reason, the cycle sequence, sizing, the agent roster. Not re-typed by the
    orchestrator, so they cannot drift from what was recorded.
  * NARRATIVE comes from the orchestrator on stdin or via --findings-file, appended
    verbatim. What the agents actually found is not derivable and should not be faked.

  pr-report.py --run-id <id> [--post] [--label] [--findings-file f] [--repo .]

Without --post it prints the report. With --post it comments on the PR for the current
branch, or — when no PR exists yet, the normal case for a fresh branch, since the push
gate forces loop-then-push-then-PR — writes .git/info/review-loop-pending-report.md
for Step 0c to flush. Deferred, never dropped.
"""
import argparse
import os
import subprocess
import sys

import runlog

MARKER = "<!-- review-loop:run={} -->"
PENDING = "info/review-loop-pending-report.md"
# At-a-glance trust, which is the point: a reader should not have to open a comment to
# learn whether the review finished. Mirrors runlog's derived vocabulary exactly.
LABELS = {
    "converged": ("review:converged", "0e8a16", "review-loop ran out of findings"),
    "capped": ("review:capped", "fbca04", "review-loop hit its agent budget with findings outstanding"),
    "halted": ("review:halted", "d93f0b", "review-loop stopped with findings outstanding"),
    "unknown": ("review:unknown", "b60205", "review-loop recorded no cycles — completeness unknown"),
}


def sh(*args, repo="."):
    """Never raise. A missing binary must read as "that command failed", not a traceback.

    `gh` absent is the ordinary case on a machine that has never installed it, and it is
    reached on the path that DEFERS the report — so letting FileNotFoundError escape
    turned "no PR yet, write the pending file" into a crash that dropped the report
    entirely. Same reason runlog.git() swallows OSError.
    """
    try:
        r = subprocess.run(args, capture_output=True, text=True, cwd=repo, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, "", str(exc)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def render(run, run_id, conv, narrative):
    cycles = runlog.cycles_of(run)
    agents = sum(c.get("agents") or 0 for c in cycles)
    tokens = sum(c.get("subagent_tokens") or 0 for c in cycles)
    out = [MARKER.format(run_id), "", "## review-loop", ""]

    # Disclosure first and unabbreviated. A capped run is allowed to push *because* it
    # says so; burying that below a table would make the push silent in practice.
    disc = runlog.disclosure(conv, run)
    if disc:
        out += [f"> **{disc}**", ""]
    else:
        out += ["Review **converged** — the final cycle found nothing left to apply.", ""]

    tier = run.get("tier_executed") or "unrecorded"
    floor = run.get("tier_floor") or "unrecorded"
    # Built as named locals rather than implicit concatenation inside the list: a
    # missing comma there silently merges two bullets into one instead of failing.
    outcome_line = (f"- **Outcome** `{run.get('outcome') or 'unrecorded'}`"
                    f" · **convergence** `{conv or 'unknown'}`"
                    f" · **tier** `{tier}` (floor `{floor}`)")
    run_line = (f"- **Run** `{run_id}` · orchestrator `{run.get('orchestrator_model') or '?'}`"
                f" · {len(cycles)} cycle(s) · {agents} agent(s)")
    if tokens:
        run_line += f" · ~{tokens:,} subagent tokens"
    out += [outcome_line, run_line, ""]

    raw, sem = run.get("changed_lines"), run.get("semantic_lines")
    if raw is not None:
        line = f"- **Size** {raw} raw line(s)"
        if sem is not None and sem != raw:
            line += f", {sem} of review surface"
        if run.get("sizing_excluded"):
            line += f" — excluded: {run['sizing_excluded']}"
        out += [line, ""]

    if cycles:
        out += ["### Cycles", "", "| # | applied | asked | defects | comment-accuracy | agents | analysis |",
                "|---|---|---|---|---|---|---|"]
        for c in cycles:
            out.append(f"| {c.get('n')} | {c.get('applied')} | {c.get('asked') or 0} |"
                       f" {c.get('defect_findings') or 0} | {c.get('comment_findings') or 0} |"
                       f" {c.get('agents') or 0} | {'changed files' if c.get('analysis_changed') else 'clean'} |")
        out.append("")

    ex = run.get("executed") or {}
    gates = run.get("gates") or {}
    if gates or ex:
        out += ["### Gates", "", "| gate | planned | status | why |", "|---|---|---|---|"]
        for g in sorted(set(gates) | set(ex)):
            pv = (gates.get(g) or {}).get("planned", "—") if isinstance(gates.get(g), dict) else "—"
            e = ex.get(g) if isinstance(ex.get(g), dict) else {}
            status = e.get("status", "**unreported**")
            why = (e.get("reason") or (gates.get(g) or {}).get("reason") or "").replace("|", "\\|")
            out.append(f"| `{g}` | {pv} | {status} | {why} |")
        out.append("")

    esc = run.get("escalations") or []
    if esc:
        out += ["### Escalated above the plan", ""]
        out += [f"- `{e.get('gate')}` — {e.get('reason')}" for e in esc if isinstance(e, dict)]
        out.append("")

    roster = run.get("agents")
    if isinstance(roster, list) and roster:
        out += ["### Agents", ""]
        out += [f"- `{a.get('id')}` ({a.get('model') or '?'}) — {a.get('status')}"
                f", {a.get('findings', '?')} finding(s)" for a in roster if isinstance(a, dict)]
        out.append("")

    if narrative:
        out += ["### Findings", "", narrative.strip(), ""]
    return "\n".join(out).rstrip() + "\n"


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--findings-file", help="orchestrator's narrative; '-' or omitted reads stdin if piped")
    ap.add_argument("--post", action="store_true", help="comment on the PR, or defer to the pending file")
    ap.add_argument("--label", action="store_true", help="also apply the review:<convergence> label")
    ap.add_argument("--repo", default=".")
    a = ap.parse_args(argv)

    run = runlog.load(limit=None).get(a.run_id)
    if not run:
        sys.exit(f"pr-report: no run {a.run_id!r} in the record")
    conv = runlog.convergence(run)

    narrative = ""
    if a.findings_file and a.findings_file != "-":
        with open(a.findings_file, encoding="utf-8") as fh:
            narrative = fh.read()
    elif not sys.stdin.isatty():
        narrative = sys.stdin.read()

    body = render(run, a.run_id, conv, narrative)
    if not a.post:
        print(body, end="")
        return 0

    rc, num, _ = sh("gh", "pr", "view", "--json", "number", "-q", ".number", repo=a.repo)
    if rc != 0 or not num:
        # No PR is the normal first-branch case, not a reason to drop the report.
        rc, gitdir, _ = sh("git", "rev-parse", "--path-format=absolute", "--git-common-dir", repo=a.repo)
        if rc != 0:
            sys.exit("pr-report: no PR and no git dir — nowhere to defer to")
        path = os.path.join(gitdir, PENDING)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        print(f"pr-report: no PR yet — deferred to {path} (Step 0c flushes it)", file=sys.stderr)
        return 0

    rc, _, err = sh("gh", "pr", "comment", num, "--body", body, repo=a.repo)
    if rc != 0:
        # Never fail the run over a failed post; say so and let the report carry it.
        print(f"pr-report: comment failed on PR #{num}: {err}", file=sys.stderr)
    else:
        print(f"pr-report: posted to PR #{num}", file=sys.stderr)

    if a.label:
        name, colour, desc = LABELS[conv or "unknown"]
        sh("gh", "label", "create", name, "--color", colour, "--description", desc, repo=a.repo)
        for old, _c, _d in LABELS.values():
            if old != name:
                sh("gh", "pr", "edit", num, "--remove-label", old, repo=a.repo)
        rc, _, err = sh("gh", "pr", "edit", num, "--add-label", name, repo=a.repo)
        print(f"pr-report: label {name}" + ("" if rc == 0 else f" failed: {err}"), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
