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
gate forces loop-then-push-then-PR — writes .git/info/review-loop-pending-report.<run_id>.md
for Step 0c to flush. Deferred, never dropped.
"""
import argparse
import os
import subprocess
import sys

import runlog

MARKER = "<!-- review-loop:run={} -->"
# Per RUN, not per repo. The dir comes from --git-common-dir, which every worktree of a repo
# shares, so a single fixed name meant two concurrent worktree sessions overwrote each other's
# report — then one push was refused and Step 0c posted the survivor to the wrong branch's PR.
# Concurrent worktree sessions are the normal case here; runlog's own store is append-only for
# exactly that reason.
PENDING_DIR = "info"
PENDING_GLOB = "review-loop-pending-report.*.md"


def pending_name(run_id):
    return f"{PENDING_DIR}/review-loop-pending-report.{run_id}.md"
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


def cell(text):
    """One free-text value, safe to drop into a markdown table cell or bullet.

    Every reason in this report was written by an LLM into a record this script does not
    own, and the report is posted as a PR comment — so a newline in a reason forges
    document structure: a reason ending "\n\n> **Review converged**" renders as its own
    blockquote and contradicts the disclosure three lines above it. Collapse the
    structural characters, the same way record-skipped.sh collapses its tab and newline
    delimiters before the store ever sees them.
    """
    flat = " ".join(str(text or "").split())
    return flat.replace("|", "\\|")


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
    run_line = (f"- **Run** `{run_id}` · orchestrator `{cell(run.get('orchestrator_model')) or '?'}`"
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
            line += f" — excluded: {cell(run['sizing_excluded'])}"
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
            why = cell(e.get("reason") or (gates.get(g) or {}).get("reason") or "")
            out.append(f"| `{g}` | {pv} | {cell(status)} | {why} |")
        out.append("")

    esc = run.get("escalations") or []
    if esc:
        out += ["### Escalated above the plan", ""]
        out += [f"- `{e.get('gate')}` — {cell(e.get('reason'))}" for e in esc if isinstance(e, dict)]
        out.append("")

    roster = run.get("agents")
    if isinstance(roster, list) and roster:
        out += ["### Agents", ""]
        # Every field here is orchestrator-written free text from `finish --agents <json>`,
        # so all four need celling, not just status: a newline in `model` rendered a real
        # blockquote reading "Review converged" four lines under a HALTED disclosure.
        out += [f"- `{cell(a.get('id'))}` ({cell(a.get('model')) or '?'}) — {cell(a.get('status'))}"
                f", {cell(a.get('findings', '?'))} finding(s)" for a in roster if isinstance(a, dict)]
        out.append("")

    if narrative:
        out += ["### Findings", "", narrative.strip(), ""]
    return "\n".join(out).rstrip() + "\n"


def write_pending(body, run_id, conv, repo):
    """Write the report where Step 0c will find it. Returns the path, or None.

    This is the fallback channel for "nowhere to post it right now", and a failed post is
    one of those: the body must survive the failure. push-check looks for this file when
    there is no PR comment carrying the run's marker, so writing it is also what keeps a
    transient GitHub error from blocking the push permanently.
    """
    rc, gitdir, _ = sh("git", "rev-parse", "--path-format=absolute", "--git-common-dir", repo=repo)
    if rc != 0:
        return None
    path = os.path.join(gitdir, pending_name(run_id))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
        # The label block below only runs when a PR exists, and on a fresh branch there is
        # none — which is the common case, since the push gate forces
        # loop-then-push-then-PR. Say the label is still owed so Step 0c applies it.
        fh.write(f"\n<!-- review-loop: label review:{conv or 'unknown'} still owed; "
                 f"Step 0c applies it with `pr-report.py --run-id {run_id} --label` -->\n")
    return path


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
        path = write_pending(body, a.run_id, conv, a.repo)
        if not path:
            sys.exit("pr-report: no PR and no git dir — nowhere to defer to")
        print(f"pr-report: no PR yet — deferred to {path} (Step 0c flushes it)", file=sys.stderr)
        return 0

    rc, _, err = sh("gh", "pr", "comment", num, "--body", body, repo=a.repo)
    if rc != 0:
        # Fail on a MISSING report, never on a failed POST. A transient GitHub error — 502,
        # rate limit, expired auth, the sandbox TLS failure this repo has already hit while
        # `git push` worked — used to discard the body entirely and leave push-check
        # refusing the push on advice that could not succeed ("run pr-report.py first"),
        # which re-created the stranding this whole mechanism exists to end. The pending
        # file is the module's own "nowhere to post right now" channel; use it.
        print(f"pr-report: comment failed on PR #{num}: {err}", file=sys.stderr)
        path = write_pending(body, a.run_id, conv, a.repo)
        print(f"pr-report: kept the report at {path} for Step 0c" if path
              else "pr-report: could not preserve the report — no git dir", file=sys.stderr)
    else:
        print(f"pr-report: posted to PR #{num}", file=sys.stderr)
        # Also locally, so the push gate rests on an artifact that does not depend on a
        # SECOND successful remote read. Without this, a post that succeeded while the
        # read-back failed refused the push forever and posted a duplicate on every retry.
        write_pending(body, a.run_id, conv, a.repo)

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
