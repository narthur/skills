#!/usr/bin/env python3
"""Threat-model staleness check for review-loop (Step 2b).

The threat model lives at `<git-common-dir>/info/review-loop-threat-model.md`.
Every OBSERVED claim carries a citation pinned to the commit it was verified at:

    - OBSERVED: All /api/v2 routes authenticate in middleware. [src/app.ts:42 @ a1b2c3d]

A claim is STALE when its cited file has changed since that pin. That is a
`git log` away, so staleness is mechanical here rather than a judgment call for
the LLM sweep — the update agent gets an exact worklist instead of "re-read the
diff and guess what's now wrong".

  threat-model.py            # JSON: {path, exists, claims, stale, broken_pins, uncited}
  threat-model.py --selftest

Exit 0 always (informational); callers read `exists` and `stale`.
"""
import json
import sys

# Shared with deferred.py: one definition of the citation shape and the staleness rule.
import pins

MODEL = "review-loop-threat-model.md"


def model_path():
    return pins.info_path(MODEL)


def report():
    path = model_path()
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, TypeError):
        return {"path": path, "exists": False, "claims": 0, "stale": [],
                "broken_pins": [], "uncited": 0}
    claims, uncited = pins.citations(text, marker="OBSERVED:")
    return {
        "path": path,
        "exists": True,
        "claims": len(claims),
        "stale": pins.stale(claims),
        # pins.broken's doctrine is "callers must report it", and this was the caller that
        # did not. A claim pinned to an unresolvable sha returns [] from stale(), so Step 2b's
        # "skip the agent when stale is empty" drops it from the worklist entirely — while it
        # still looks pinned and stays out of `uncited`. For a `Not an issue here` dismissal,
        # which is the security review's per-repo suppression channel, that is a suppression
        # nothing ever re-examines.
        "broken_pins": pins.broken(claims),
        "uncited": uncited,
    }


def _selftest():
    # The parsing itself is pins' own selftest. This proves the wiring: the shared
    # primitives are reached, and OBSERVED is the marker this artifact owes a pin on.
    claims, uncited = pins.citations(
        "- OBSERVED: pinned. [src/app.ts:42 @ a1b2c3d]\n"
        "- OBSERVED: unpinned, so nothing can ever mark it stale.\n", marker="OBSERVED:")
    assert len(claims) == 1 and uncited == 1, (claims, uncited)
    assert model_path().endswith(MODEL) or model_path() == ""
    # report() itself was never called by this selftest, so broken_pins, stale and the
    # exists:False branch were all uncovered — replacing broken_pins with [] left every suite
    # green, and the suppression-nothing-re-examines hazard it was added for was silently back.
    import os
    import tempfile
    cwd = os.getcwd()
    with tempfile.TemporaryDirectory() as td:
        try:
            os.chdir(td)
            for cmd in (("init", "-q", "."), ("config", "user.email", "t@t"),
                        ("config", "user.name", "t")):
                pins.git(*cmd)
            with open("app.py", "w", encoding="utf-8") as fh:
                fh.write("x = 1\n")
            pins.git("add", "-A")
            pins.git("-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                     "commit", "-qm", "seed")
            real = pins.git("rev-parse", "HEAD")
            assert real, "fixture has no HEAD"
            info = os.path.join(td, ".git", "info")
            os.makedirs(info, exist_ok=True)
            with open(os.path.join(info, MODEL), "w", encoding="utf-8") as fh:
                fh.write(
                    f"- OBSERVED — resolvable pin. [app.py:1 @ {real}]\n"
                    "- OBSERVED — unresolvable pin, so staleness can never be computed. "
                    "[app.py:1 @ deadbeefcafe]\n")
            got = report()
            assert got["exists"] is True, got
            assert got["claims"] == 2, got
            assert [c["sha"] for c in got["broken_pins"]] == ["deadbeefcafe"], got["broken_pins"]
            assert got["stale"] == [], got["stale"]
        finally:
            os.chdir(cwd)
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--selftest"]:
        _selftest()
    else:
        print(json.dumps(report(), indent=2))
