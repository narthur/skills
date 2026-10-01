#!/usr/bin/env python3
"""Deferred findings and when they come back (Step 2a).

A reachability deferral is a grounded judgment, not a dodge: the review happened, the
finding is real, and the only claim is that nothing exercises it *today*. Nathan's
distinction, and it holds — "this already exists in the repo so I needn't look" is a
reason not to review; "I reviewed, found this, and it cannot fire yet" is a conclusion
from having reviewed.

The danger is not the deferral. It is that a deferral is right today and silently
permanent. "No async Sketch exists, so the draws cannot overlap" was true when written
and becomes false the moment someone writes the second Sketch — which is exactly when
the finding matters and exactly when nobody remembers it exists. So every deferral is
pinned to the file whose change would invalidate its grounding, and comes back as a
worklist item when that file moves.

Lives at `<git-common-dir>/info/review-loop-deferred.md`. One entry per finding:

    - DEFERRED 2026-10-01 (run b480b45cc65d): two async Sketch draws could overlap and
      corrupt the canvas mid-render.
      Grounding: no async Sketch exists; `trails` is synchronous. [src/bands/types.ts:14 @ a1b2c3d]
      Guard: none — a type-level assertion would need a new test file, so not cheap.

An entry with no pin is the dangerous one: nothing can ever mark it stale, so it
survives the change that invalidated it. Those are counted and reported separately
rather than quietly tolerated.

  deferred.py            # JSON: {path, exists, entries, stale, unpinned}
                         # `unpinned` NAMES the entries that can never go stale.
  deferred.py --selftest

Exit 0 always (informational); callers read `stale` and `unpinned`.
"""
import json
import sys

import pins

DEFERRED = "review-loop-deferred.md"
MARKER = "DEFERRED"


def path():
    return pins.info_path(DEFERRED)


def entries(text):
    """-> list of {line, text, pins}. One per DEFERRED marker, as a BLOCK.

    Parsed as blocks rather than lines because an entry's pin lives on its Grounding
    line, not on its DEFERRED line. Counting citations line-wise paired nothing, so
    every entry read as unpinned and the signal was worthless — caught by this
    module's own selftest before it shipped.
    """
    out = []
    for n, raw in enumerate(text.splitlines(), 1):
        if MARKER in raw:
            out.append({"line": n, "text": [raw], "pins": []})
        elif out:
            out[-1]["text"].append(raw)
    for e in out:
        block = "\n".join(e["text"])
        e["pins"], _ = pins.citations(block)
        # Pin line numbers are block-relative from citations(); make them file-absolute
        # so a reader can jump to them.
        for c in e["pins"]:
            c["line"] += e["line"] - 1
        e["text"] = block.strip()
    return out


def report():
    p = path()
    try:
        with open(p, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, TypeError):
        return {"path": p, "exists": False, "entries": 0, "stale": [], "unpinned": []}
    es = entries(text)
    allpins = [c for e in es for c in e["pins"]]
    return {
        "path": p,
        "exists": True,
        "entries": len(es),
        "stale": pins.stale(allpins),
        # An entry with no pin can never be marked stale, so it survives the change
        # that invalidated it. Named, not just counted, because the fix is to pin it.
        "unpinned": [{"line": e["line"], "text": e["text"].splitlines()[0]} for e in es if not e["pins"]],
    }


def _selftest():
    text = (
        "# Deferred findings\n\n"
        "- DEFERRED 2026-10-01 (run abc123abc123): async draws could overlap.\n"
        "  Grounding: no async Sketch exists. [src/bands/types.ts:14 @ a1b2c3d]\n"
        "  Guard: none — would need a new test file.\n\n"
        "- DEFERRED 2026-10-01 (run abc123abc123): no pin on this one.\n"
        "  Grounding: nothing uses it.\n"
    )
    es = entries(text)
    assert len(es) == 2, es
    # The pin is found even though it sits on a different line from the marker — the
    # line-wise version paired nothing and reported every entry unpinned.
    assert len(es[0]["pins"]) == 1, es[0]
    assert es[0]["pins"][0]["path"] == "src/bands/types.ts"
    assert es[0]["pins"][0]["line"] == 4, es[0]["pins"]   # file-absolute, not block-relative
    assert es[1]["pins"] == [], es[1]
    # The Guard line belongs to its entry, not to the next one.
    assert "Guard: none" in es[0]["text"] and "Guard" not in es[1]["text"]
    # A file with no entries is not an error.
    assert entries("# Deferred findings\n\nnothing yet\n") == []
    assert path().endswith(DEFERRED) or path() == ""
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--selftest"]:
        _selftest()
    else:
        print(json.dumps(report(), indent=2))
