#!/usr/bin/env python3
"""Stamp a learnings file with the entry count a sweep left behind.

`context.sh` will not re-arm the compaction trigger until the file has grown past this
number, so the marker is what stops a relevance-based sweep from re-spawning an agent
every run for zero evictions. It exists as a script because the format had no producer:
the only instruction to write it was prose aimed at an LLM, and a missing space, a
different dash, or a CRLF line ending silently reverted the trigger to its bare-count
behaviour with nothing reporting that it had. Counting here also means the number cannot
disagree with the file it is written into.

  mark-swept.py <learnings-file>
  mark-swept.py --selftest
"""
import re
import sys

MARKER = re.compile(r"^[ \t]*<!--[ \t]*[Ss]wept:")


def restamp(text):
    """Returns the file with exactly one trailing marker, counting live entries."""
    lines = [l for l in text.splitlines() if not MARKER.match(l)]
    while lines and not lines[-1].strip():
        lines.pop()
    entries = sum(1 for l in lines if l.startswith("- "))
    lines.append(f"<!-- swept: {entries} -->")
    return "\n".join(lines) + "\n", entries


def _selftest():
    out, n = restamp("# H\n\n- a\n- b\n")
    assert out == "# H\n\n- a\n- b\n<!-- swept: 2 -->\n", repr(out)
    assert n == 2
    # an existing marker is REPLACED, not appended to: two markers is a record of two
    # different answers to one question, and the reader can only take one.
    out, n = restamp("# H\n\n- a\n<!-- swept: 99 -->\n")
    assert out.count("swept") == 1 and "swept: 1" in out, repr(out)
    # every variant the reader tolerates is also replaced, or the stamp would double up
    for odd in ("<!--  Swept:  99 -->", "   <!-- swept: 99 -->"):
        out, _ = restamp(f"# H\n\n- a\n{odd}\n")
        assert out.count("swept") == 1, repr(out)
    # a marker is not an entry, so re-stamping twice is stable
    once, _ = restamp("# H\n\n- a\n")
    twice, _ = restamp(once)
    assert once == twice, (once, twice)
    # the reader's own pattern must accept what this writes
    assert re.match(r"^[ \t]*<!--[ \t]*[Ss]wept:[ \t]*([0-9]{1,}).*$",
                    once.splitlines()[-1]).group(1) == "1"
    print("ok")


def main(argv):
    if argv[:1] == ["--selftest"]:
        return _selftest() or 0
    if len(argv) != 1:
        sys.exit(__doc__)
    path = argv[0]
    with open(path) as f:
        out, n = restamp(f.read())
    with open(path, "w") as f:
        f.write(out)
    print(f"marked swept at {n} entries: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
