#!/usr/bin/env python3
"""Deterministic score->bucket routing for review-loop (Steps 6d / 8a).

The LLM keeps the judgment — the Haiku score (Step 6), the Step 8a risk
classification, and the always-ask hard rules. This script only does the
mechanical bucketing, so the thresholds land identically every run.

  echo '<findings-json>' | bucket.py
  bucket.py --selftest

Input: JSON array of findings, each {id, agent, score, risk, always_ask,
cost_recurrence, category, behavioral, observed_failure}.
Use these exact agent ids; any other string gets the default routing.
- agent "7-structural" or "9-intent" -> always ask (a proposal, never auto-applied), even at >=80.
- agent "5-security-authz" -> always ask (an authz fix locks real users out if wrong).
- security agents -> nothing below 80 is actioned; see SECURITY_AGENTS below. This runs
  FIRST, so it applies to 5-security-authz too: an authz finding the Stage-2 filter scored
  under 80 is report-only (listed line-by-line at Step 14), not asked. "Never auto-apply"
  is what always-ask buys authz; it does not exempt it from the security floor.
- always_ask true -> ask (unclear/conflicting fix, or CLAUDE.md / learnings 'always ask about X').
- any always-ask finding scoring < ASK_FLOOR -> skip (report-only, still never auto-applied).
- risk "low"/"high" is consulted only for 50-79; missing risk defaults to ask (safe).
- cost_recurrence "per-use"/"per-item" -> never skip; floors to ask. A cost paid on
  repetition is systematically under-rated by a diff-scoped reviewer, because the diff
  shows the fix's size and not the operation's frequency.
- category "comment-accuracy" WITH a recurring cost_recurrence -> refused as a
  contradiction, because that exact miscategorisation is what this is for.
- behavioral true without observed_failure -> never auto_fix; floors to ask.
Output: {auto_fix, ask, skip} lists, each entry tagged with its routing reason.
"""
import json
import sys

# Security findings are scored by the Stage-2 false-positive filter, not Haiku
# (score = filter confidence x 10). Upstream's threshold is 8/10, and honoring it
# is most of what buys the low false-positive rate — so security has no 50-79 ask
# band. Sub-80 is skipped here but NOT lost: Step 14 lists it in the report, which
# is the only place a wrongly-dropped security finding can surface for a non-expert.
SECURITY_AGENTS = {"5-security", "5-security-authz"}
SECURITY_FLOOR = 80

ASK_ALWAYS_AGENTS = {"7-structural", "9-intent", "5-security-authz"}

# Always-ask routing keeps a finding from being auto-applied; it is not a reason
# to interrupt the user at any score. Without a floor a score-0 structural nit
# reached the user alongside a 65. Below the floor it is listed in the Step 14
# report (#7 nits / #9 questions) instead of asked.
ASK_FLOOR = 40

# A cost paid once is bounded by the change; a cost paid per use or per item scales with
# how the system is operated, which is a fact about the world and not about the diff.
# Every agent here sees only a diff, so it rates severity by how local the fix looks: a
# cache-key change that re-renders every prior artifact on each new opt-in was filed as
# a comment-wording nit, recommending softer prose, when the real cost was ~70 minutes
# of CI per rollout. Detection worked; calibration did not. A recurring cost therefore
# cannot be skipped on a low score — it reaches a human, who can see the frequency.
RECURRENCE = ("once", "per-use", "per-item")
RECURRING = ("per-use", "per-item")


class Contradiction(Exception):
    """The finding describes two incompatible things; the agent must resolve it, not us."""


def _validate(f):
    """Refuse a finding we cannot route honestly, rather than guessing a default.

    An unrecognised cost_recurrence must not fall back to "once": a typo would silently
    buy the cheaper routing, which is the whole failure mode this field exists to close.
    """
    rec = f.get("cost_recurrence")
    if rec is not None and rec not in RECURRENCE:
        raise Contradiction(
            f"finding {f.get('id', '?')!r}: cost_recurrence {rec!r} is not one of "
            f"{', '.join(RECURRENCE)} — a value we cannot read must not default to the cheapest"
        )
    if rec in RECURRING and f.get("category") == "comment-accuracy":
        raise Contradiction(
            f"finding {f.get('id', '?')!r}: category 'comment-accuracy' with cost_recurrence "
            f"{rec!r} is a contradiction. A cost paid on every use is not a wording problem. "
            "This is the exact miscategorisation the field exists to catch: decide whether the "
            "consequence recurs, and if it does, file it as the defect it is."
        )


def route(f):
    _validate(f)
    agent = f.get("agent", "")
    score = int(f.get("score", 0))
    recurring = f.get("cost_recurrence") in RECURRING
    # A behavioral claim with no observed failure may be a no-op. One run "fixed" CRLF
    # frontmatter handling with a regex that already worked, and its verification — run
    # only AFTER the change — passed exactly as it would have without it. A check that
    # never saw the failure cannot tell a fix from a no-op, so the fix is not auto-applied.
    unproven = bool(f.get("behavioral")) and not (f.get("observed_failure") or "").strip()
    if agent in SECURITY_AGENTS and score < SECURITY_FLOOR:
        return "skip", "security: filter confidence < 8/10 (report-only, Step 14)"
    if agent in ASK_ALWAYS_AGENTS or f.get("always_ask"):
        if score < ASK_FLOOR:
            return "skip", f"always-ask below {ASK_FLOOR}: report-only (Step 14), never auto-applied"
        if agent in ASK_ALWAYS_AGENTS:
            return "ask", f"{agent}: proposal, never auto-applied"
        return "ask", "hard rule: unclear/conflicting fix or 'always ask' guidance"
    if unproven:
        return "ask", ("behavioral claim with no observed failure — construct the failing case "
                       "and watch it fail before applying a fix")
    if score >= 80:
        return "auto_fix", "score >= 80"
    if score >= 50:
        if f.get("risk") == "low":
            return "auto_fix", "50-79, low-risk (Step 8a)"
        return "ask", "50-79, high-risk (Step 8a)"
    if recurring:
        return "ask", (f"score < 50 but the cost is {f['cost_recurrence']} — a recurring cost is "
                       "rated by how local the fix looks, so it does not get skipped on score")
    return "skip", "score < 50"


def bucket(findings):
    out = {"auto_fix": [], "ask": [], "skip": []}
    for f in findings:
        b, reason = route(f)
        out[b].append({**f, "bucket": b, "reason": reason})
    return out


def main_bucket(findings):
    """Route a batch, refusing all of it if any finding contradicts itself.

    Refusing the whole batch is deliberate: dropping just the bad finding would quietly
    lose the one the agent described incorrectly, which is the finding most worth a
    second look.
    """
    try:
        return bucket(findings)
    except Contradiction as exc:
        sys.exit(f"bucket: refusing to route — {exc}")


def _selftest():
    assert route({"agent": "2-bugs", "score": 85})[0] == "auto_fix"
    assert route({"agent": "2-bugs", "score": 60, "risk": "low"})[0] == "auto_fix"
    assert route({"agent": "2-bugs", "score": 60, "risk": "high"})[0] == "ask"
    assert route({"agent": "2-bugs", "score": 60})[0] == "ask"          # missing risk -> ask
    assert route({"agent": "2-bugs", "score": 40})[0] == "skip"
    assert route({"agent": "7-structural", "score": 95})[0] == "ask"    # overrides >=80
    assert route({"agent": "9-intent", "score": 90})[0] == "ask"
    assert route({"agent": "2-bugs", "score": 90, "always_ask": True})[0] == "ask"
    # Always-ask floor: low-value proposals are report-only, not interruptions.
    assert route({"agent": "7-structural", "score": 0})[0] == "skip"
    assert route({"agent": "7-structural", "score": 39})[0] == "skip"
    assert route({"agent": "7-structural", "score": 40})[0] == "ask"
    assert route({"agent": "9-intent", "score": 28})[0] == "skip"
    assert route({"agent": "2-bugs", "score": 20, "always_ask": True})[0] == "skip"
    # Security: no 50-79 band — sub-80 is report-only, never an interruption.
    assert route({"agent": "5-security", "score": 70, "risk": "low"})[0] == "skip"
    assert route({"agent": "5-security", "score": 60, "risk": "high"})[0] == "skip"
    assert route({"agent": "5-security", "score": 80, "risk": "low"})[0] == "auto_fix"
    # Authz always asks above the floor, and is still floored below it.
    assert route({"agent": "5-security-authz", "score": 100, "risk": "low"})[0] == "ask"
    assert route({"agent": "5-security-authz", "score": 70})[0] == "skip"

    # --- cost_recurrence: a recurring cost is never skipped on score alone.
    assert route({"agent": "2-bugs", "score": 20, "cost_recurrence": "per-item"})[0] == "ask"
    assert route({"agent": "2-bugs", "score": 20, "cost_recurrence": "per-use"})[0] == "ask"
    assert route({"agent": "2-bugs", "score": 20, "cost_recurrence": "once"})[0] == "skip"
    assert route({"agent": "2-bugs", "score": 20})[0] == "skip"
    # It floors, never ceilings: high confidence still auto-fixes.
    assert route({"agent": "2-bugs", "score": 85, "cost_recurrence": "per-item"})[0] == "auto_fix"
    # And it overrides neither always-ask nor the security floor.
    assert route({"agent": "7-structural", "score": 10, "cost_recurrence": "per-item"})[0] == "skip"
    assert route({"agent": "5-security", "score": 70, "cost_recurrence": "per-item"})[0] == "skip"
    # An unreadable value must NOT fall back to the cheapest routing.
    for bogus in ("per_item", "peritem", "PER-ITEM", "recurring", ""):
        try:
            route({"agent": "2-bugs", "score": 20, "cost_recurrence": bogus})
        except Contradiction:
            pass
        else:
            raise AssertionError(f"cost_recurrence {bogus!r} should be refused")

    # --- the Bands miscategorisation: a recurring cost filed as a wording nit.
    for rec in ("per-use", "per-item"):
        try:
            route({"agent": "4-comments", "score": 30, "category": "comment-accuracy",
                   "cost_recurrence": rec})
        except Contradiction:
            pass
        else:
            raise AssertionError(f"comment-accuracy + {rec} should be refused")
    # A comment-accuracy finding whose cost really is one-off is perfectly normal.
    assert route({"agent": "4-comments", "score": 30, "category": "comment-accuracy",
                  "cost_recurrence": "once"})[0] == "skip"
    assert route({"agent": "4-comments", "score": 85, "category": "comment-accuracy"})[0] == "auto_fix"

    # --- behavioral claims need the failure observed, not a check that passed after.
    assert route({"agent": "2-bugs", "score": 95, "behavioral": True})[0] == "ask"
    assert route({"agent": "2-bugs", "score": 95, "behavioral": True,
                  "observed_failure": "   "})[0] == "ask"      # whitespace is not evidence
    assert route({"agent": "2-bugs", "score": 95, "behavioral": True,
                  "observed_failure": "node -e showed $ matching before CRLF"})[0] == "auto_fix"
    # Non-behavioral findings are unaffected: a typo fix owes no failing case.
    assert route({"agent": "4-comments", "score": 95})[0] == "auto_fix"
    # The security floor still outranks it.
    assert route({"agent": "5-security", "score": 70, "behavioral": True})[0] == "skip"
    print("ok")


def main(argv):
    if argv and argv[0] == "--selftest":
        _selftest()
        return 0
    print(json.dumps(main_bucket(json.load(sys.stdin)), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
