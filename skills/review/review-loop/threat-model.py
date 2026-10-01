#!/usr/bin/env python3
"""Threat-model staleness check for review-loop (Step 2b).

The threat model lives at `<git-common-dir>/info/review-loop-threat-model.md`.
Every OBSERVED claim carries a citation pinned to the commit it was verified at:

    - OBSERVED: All /api/v2 routes authenticate in middleware. [src/app.ts:42 @ a1b2c3d]

A claim is STALE when its cited file has changed since that pin. That is a
`git log` away, so staleness is mechanical here rather than a judgment call for
the LLM sweep — the update agent gets an exact worklist instead of "re-read the
diff and guess what's now wrong".

  threat-model.py            # JSON: {path, exists, claims, stale, uncited}
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
        return {"path": path, "exists": False, "claims": 0, "stale": [], "uncited": 0}
    claims, uncited = pins.citations(text, marker="OBSERVED:")
    return {
        "path": path,
        "exists": True,
        "claims": len(claims),
        "stale": pins.stale(claims),
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
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--selftest"]:
        _selftest()
    else:
        print(json.dumps(report(), indent=2))
