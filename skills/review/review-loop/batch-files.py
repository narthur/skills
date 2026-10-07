#!/usr/bin/env python3
"""Pack a cycle's changed files into context-bounded batches for the
file-scoped review agents (#1 CLAUDE.md, #2 bugs, #4 comments).

Those agents review the WHOLE changed file (omission bugs are invisible in a
diff-of-additions). Handing one agent every file dilutes attention (measured:
whole-PR context tanked recall); one agent per file is needless fan-out. So we
greedily bin-pack files under a target line budget and run one instance of each
file-scoped agent per batch, in parallel. Disjoint batches → no cross-instance
dedup needed.

  batch-files.py <diff-range> [--target 1500] [--hardcap 2500]
  batch-files.py --selftest

<diff-range> is anything git diff accepts (origin/main...HEAD, <sha>...HEAD).
Emits JSON: batches (each a list of files under the target), plus oversized
files that must fall back to diff-plus-enclosing-scope so one giant file can't
re-dilute a batch. Small PR -> one batch -> identical to the pre-batching flow.

Files carrying the SAME edit are collapsed to one representative. Packing by
file size alone measured the wrong thing: nine test suites received one
identical check-count guard, split across four batches, and cost twelve agents
for a change there was mostly one of. Six of those nine normalize to one
fingerprint; the other three carried extra edits and correctly do not group.
Batch counts are range-specific and not a ratio to expect: on aaaebb4...1de3722
collapsing changes nothing, on the branch that added this it goes five to four.
An earlier docstring claimed four-to-three on that first range -- a reduction
that existed only while the budget ignored the sibling hunks the agents read. `near_duplicates` maps each representative to
the siblings it stands for, and the caller reviews the representative whole
plus each sibling's hunk. Reading nine copies of one edit does not find a
tenth suite that should have had it and doesn't -- only counting suites does,
which is a different check.

ponytail: line count is the lazy proxy for a context budget; swap to a token
count only if it ever misjudges. Greedy first-fit-decreasing, not optimal
bin-packing — batches are a soft budget, not a constraint to minimize.
"""
import argparse
import hashlib
import json
import re
import subprocess
import sys


def head_ref(diff_range):
    r = diff_range.strip()
    for sep in ("...", ".."):
        if sep in r:
            return r.split(sep)[-1] or "HEAD"
    return r or "HEAD"


def changed_files(diff_range):
    """Added/modified files (skip deletions — no 'after' file to review)."""
    out = subprocess.run(["git", "diff", "--name-status", diff_range],
                         capture_output=True, text=True).stdout
    files = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        status = parts[0]
        if status.startswith("D"):
            continue
        files.append(parts[-1])  # for renames (Rxxx) the new path is last
    return files


def file_lines(head, path):
    p = subprocess.run(["git", "show", f"{head}:{path}"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return None  # binary/missing/unreadable
    return p.stdout.count("\n") + (0 if p.stdout.endswith("\n") or not p.stdout else 1)


def _norm(line):
    """A changed line stripped of what makes two copies of one edit look different:
    indentation, run-length of spaces, and integer literals. `EXPECTED_CHECKS=20`
    and `EXPECTED_CHECKS=33` are the same edit; the numbers are checked per-file
    against each suite, not by re-reading the block nine times."""
    return line[0] + re.sub(r"\d+", "#", " ".join(line[1:].split()))


def fingerprint(diff_range, path):
    """(hash, hunk-line count) for a file's normalized hunk lines. Empty hash when
    there is nothing to hash (unreadable, or a diff with no +/- lines), which never
    groups. The count is returned because a collapsed group's agents still read every
    SIBLING's hunk, and those lines have to reach the budget."""
    # :(top) because `changed_files` yields repo-root-relative paths while a bare
    # pathspec resolves against the cwd, which is not the root when run from a subdir.
    p = subprocess.run(["git", "diff", "-U0", diff_range, "--", f":(top){path}"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return "", 0
    lines = [_norm(l) for l in p.stdout.splitlines()
             if l[:1] in ("+", "-") and not l.startswith(("+++", "---"))]
    if not lines:
        return "", 0
    return hashlib.sha1("\n".join(lines).encode()).hexdigest(), len(lines)


def collapse(sizes, prints, hunks=None):
    """Group files whose edits normalize identically. Returns (sizes, near_dups):
    sizes keeps one representative per group (the largest file -- most context for
    the pattern), near_dups maps it to the siblings it stands for.

    The representative's size CARRIES ITS SIBLINGS' HUNK LINES. The agents read the
    representative whole plus each sibling's hunk, so counting the representative
    alone under-reports what they are handed -- six siblings at twenty lines is 120
    lines the budget never saw, and the oversized-file check never saw them either.
    Under-counting buys a cheaper review, which is the direction a size measure must
    never err in."""
    hunks = hunks or {}
    groups = {}
    for path, n in sizes:
        groups.setdefault(prints.get(path) or path, []).append((path, n))
    kept, near_dups = [], {}
    for key, members in groups.items():
        members.sort(key=lambda x: (-x[1], x[0]))
        rep, rep_n = members[0]
        siblings = [p for p, _ in members[1:]]
        kept.append((rep, rep_n + sum(hunks.get(p, 0) for p in siblings)))
        if siblings:
            near_dups[rep] = siblings
    kept.sort(key=lambda x: x[0])
    return kept, near_dups


def pack(sizes, target, hardcap):
    """sizes: list of (path, lines). Returns (batches, oversized_fallback)."""
    fallback = [{"file": p, "lines": n, "mode": "diff+enclosing-scope"}
                for p, n in sizes if n > hardcap]
    solo = [(p, n) for p, n in sizes if target < n <= hardcap]
    normal = sorted([(p, n) for p, n in sizes if n <= target], key=lambda x: -x[1])

    batches = []
    for p, n in normal:  # first-fit-decreasing
        for b in batches:
            if b["lines"] + n <= target:
                b["files"].append(p)
                b["lines"] += n
                break
        else:
            batches.append({"files": [p], "lines": n})
    for p, n in solo:  # each over-target-but-reviewable file gets its own batch
        batches.append({"files": [p], "lines": n})
    return batches, fallback


def _selftest():
    b, f = pack([("a", 900), ("b", 800), ("c", 400), ("d", 100)], 1500, 2500)
    assert all(x["lines"] <= 1500 for x in b), b
    assert sum(len(x["files"]) for x in b) == 4
    assert f == []
    # a file between target and hardcap -> its own batch, whole file kept
    b, f = pack([("big", 2000), ("x", 300)], 1500, 2500)
    assert {"files": ["big"], "lines": 2000} in b
    assert f == []
    # a file over hardcap -> fallback, not a batch
    b, f = pack([("huge", 5000), ("x", 300)], 1500, 2500)
    assert f and f[0]["file"] == "huge" and f[0]["mode"] == "diff+enclosing-scope"
    assert all("huge" not in x["files"] for x in b)
    # empty
    assert pack([], 1500, 2500) == ([], [])

    # one identical edit across nine files collapses to one representative,
    # and the eight it stands for are named rather than dropped
    nine = [(f"s{i}.test.sh", 200 + i) for i in range(9)]
    kept, dups = collapse(nine, {p: "same" for p, _ in nine})
    assert [p for p, _ in kept] == ["s8.test.sh"], kept
    assert sorted(dups["s8.test.sh"]) == sorted(p for p, _ in nine[:8]), dups

    # The representative's size must CARRY the siblings' hunk lines. Counting the
    # representative alone handed the agents eight extra hunks the budget never saw,
    # and the oversized check never saw them either -- an under-count, which is the
    # direction a size measure must never err in.
    kept, _ = collapse(nine, {p: "same" for p, _ in nine},
                       {p: 20 for p, _ in nine})
    assert kept == [("s8.test.sh", 208 + 8 * 20)], kept
    # A lone file has no siblings, so nothing is added to it.
    kept, dups = collapse([("solo.py", 100)], {"solo.py": "x"}, {"solo.py": 20})
    assert kept == [("solo.py", 100)] and dups == {}, (kept, dups)
    # Over the hardcap only BECAUSE of its siblings: the group still falls back
    # rather than silently riding inside a batch it does not fit.
    big = [(f"b{i}.py", 1200) for i in range(3)]
    kept, _ = collapse(big, {p: "same" for p, _ in big}, {p: 900 for p, _ in big})
    b, f = pack(kept, 1500, 2500)
    # b0 is the representative: equal sizes tie-break on path, not on order.
    assert f and f[0]["file"] == "b0.py" and f[0]["lines"] == 1200 + 2 * 900, (b, f)

    # a differing integer literal is still the same edit
    a = _norm("+\tEXPECTED_CHECKS=20")
    assert a == _norm("+        EXPECTED_CHECKS=33"), a
    # a differing identifier is NOT
    assert a != _norm("+\tEXPECTED_GATES=20")
    # the sign is part of the edit: an added line and a removed one differ
    assert _norm("+x = 1") != _norm("-x = 1")

    # distinct edits never group, and an unfingerprintable file groups with
    # nothing (keyed on its own path, not on the shared empty string)
    kept, dups = collapse([("a", 10), ("b", 10)], {"a": "", "b": ""})
    assert sorted(p for p, _ in kept) == ["a", "b"], kept
    assert dups == {}, dups
    print("ok")


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("diff_range", nargs="?")
    ap.add_argument("--target", type=int, default=1500,
                    help="line budget per file-scoped agent batch")
    ap.add_argument("--hardcap", type=int, default=2500,
                    help="a file bigger than this falls back to diff+enclosing scope")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)
    if args.selftest:
        _selftest()
        return 0
    if not args.diff_range:
        ap.error("diff_range is required")

    head = head_ref(args.diff_range)
    sizes, unreadable = [], []
    for path in changed_files(args.diff_range):
        n = file_lines(head, path)
        (sizes if n is not None else unreadable).append((path, n))
    fps = {p: fingerprint(args.diff_range, p) for p, _ in sizes}
    prints = {p: fp for p, (fp, _) in fps.items()}
    hunks = {p: n for p, (_, n) in fps.items()}
    sizes, near_dups = collapse(sizes, prints, hunks)
    batches, fallback = pack(sizes, args.target, args.hardcap)
    print(json.dumps({
        "target": args.target,
        "hardcap": args.hardcap,
        "n_batches": len(batches),
        "batches": batches,
        "near_duplicates": near_dups,
        "collapsed_files": sum(len(v) for v in near_dups.values()),
        "oversized_fallback": fallback,
        "unreadable_skipped": [p for p, _ in unreadable],
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
