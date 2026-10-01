#!/usr/bin/env python3
"""Pinned-claim primitives, shared by the threat model and the deferred-findings list.

Both artifacts make the same kind of statement: something that was true about the code
at a particular commit, and whose validity expires when a cited file moves. Staleness is
therefore a `git log` away rather than a judgment call — the consumer gets an exact
worklist instead of "re-read the diff and guess what's now wrong".

One definition, imported by both, because two copies of this regex and this staleness
rule would drift. Today's work is full of bugs that were exactly that: a vocabulary
restated in a second place and then silently diverging.
"""
import re
import subprocess

# [path:line @ sha] or [path:start-end @ sha] or [path @ sha]
CITATION = re.compile(r"\[([^\]\s:]+)(?::(\d+(?:-\d+)?))?\s*@\s*([0-9a-f]{7,40})\]")


def git(*args):
    try:
        p = subprocess.run(["git", *args], capture_output=True, text=True, check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    return p.stdout.strip() if p.returncode == 0 else ""


def info_path(name):
    """`<git-common-dir>/info/<name>`, or "" outside a repo.

    --git-common-dir, never --git-dir: in a linked worktree the latter has no info/, so
    the artifact would be written somewhere the next run cannot find it.
    """
    common = git("rev-parse", "--git-common-dir")
    return f"{common}/info/{name}" if common else ""


def citations(text, marker=None):
    """-> (pinned, unpinned). pinned are {line, path, lines, sha}.

    `unpinned` counts lines carrying `marker` but no citation. An unpinned claim is the
    dangerous one: nothing can ever mark it stale, so it silently survives the change
    that invalidated it. Callers surface that count rather than ignoring it.
    """
    pinned, unpinned = [], 0
    for n, raw in enumerate(text.splitlines(), 1):
        m = CITATION.search(raw)
        if m:
            pinned.append({"line": n, "path": m.group(1), "lines": m.group(2), "sha": m.group(3)})
        elif marker and marker in raw:
            unpinned += 1
    return pinned, unpinned


def resolvable(sha):
    """Does this sha name a commit in this repo? Distinguishes 'fresh' from 'uncheckable'."""
    try:
        p = subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"],
                           capture_output=True, text=True, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return p.returncode == 0


def stale(pinned):
    """Those whose cited file moved since the pin, each with the commits that moved it.

    Only pins that can actually be checked. `git()` returns "" on failure and an empty
    log is also "", so an unresolvable sha — a typo, a rebased-away commit, a sha from
    another repo — used to read as "nothing touched it" and so stayed fresh forever,
    while still counting as pinned and therefore staying out of `unpinned` too. That is
    worse than no pin at all: it looks checked and is unwatched. Those come back from
    `broken()` instead.
    """
    out = []
    for c in pinned:
        if not resolvable(c["sha"]):
            continue
        touched = git("log", "--oneline", f"{c['sha']}..HEAD", "--", c["path"])
        if touched:
            out.append({**c, "commits": touched.splitlines()})
    return out


def broken(pinned):
    """Pins whose sha does not name a commit here, so staleness can never be computed."""
    return [c for c in pinned if not resolvable(c["sha"])]


def _selftest():
    p, u = citations(
        "- OBSERVED: routes authenticate in middleware. [src/app.ts:42 @ a1b2c3d]\n"
        "- OBSERVED: token lifecycle. [src/auth.ts:10-30 @ deadbeefcafe]\n"
        "- OBSERVED: whole-file claim. [src/db.ts @ 0123456]\n"
        "- OBSERVED: no citation, so it is really an inference.\n"
        "- INFERRED: task text is user-authored and untrusted.\n",
        marker="OBSERVED:",
    )
    assert len(p) == 3, p
    assert p[0] == {"line": 1, "path": "src/app.ts", "lines": "42", "sha": "a1b2c3d"}, p[0]
    assert p[1]["lines"] == "10-30"
    assert p[2]["lines"] is None
    assert u == 1, u            # the uncited OBSERVED counts; the INFERRED does not
    assert not CITATION.search("[not a citation]")
    # No marker means no unpinned counting — the caller decides what owes a pin.
    assert citations("- OBSERVED: nothing pinned\n")[1] == 0
    print("ok")


if __name__ == "__main__":
    _selftest()
