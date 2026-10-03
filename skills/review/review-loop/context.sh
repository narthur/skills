#!/usr/bin/env bash
# review-loop context gatherer. Emits one JSON blob with everything the
# orchestrator needs to start a run — base branch (fetched),
# learnings, test/lint commands, diff size, fast-path eligibility.
# Replaces the per-step bash round-trips of SKILL Steps 1-3 + 3b-sizing.
# ponytail: one deterministic call instead of six reasoned steps.
set -uo pipefail

# base branch: PR base -> repo default -> origin/HEAD symbolic ref
base_branch=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null || true)
[ -z "$base_branch" ] && base_branch=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)
[ -z "$base_branch" ] && base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)

[ -n "$base_branch" ] && git fetch origin "$base_branch" >/dev/null 2>&1 || true

learnings=""
learnings_entries=0
# ponytail: --git-common-dir, not .git — inside a worktree .git is a file, and the
# learnings belong to the repo, not the worktree. Resolves in both cases.
lf="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)/info/review-loop-learnings.md"
if [ -f "$lf" ]; then
  learnings=$(cat "$lf")
  # No `|| echo 0`: `grep -c` prints a count AND exits 1 when nothing matches, so under
  # pipefail both the count and the fallback landed, making this the string "0\n0" — the
  # same shape removed from changed_lines, which that commit said to check for and missed
  # here. A learnings file that exists with no `- ` entries (a fresh header-only file, or
  # one the compaction sweep emptied) crashed context.sh and truncated its own output to
  # 0 bytes, because Step 1 redirects into review-loop-context.json.
  learnings_entries=$(grep -c '^- ' "$lf" 2>/dev/null) || learnings_entries=0
  # What the file counted the last time a sweep finished. The trigger below is a COUNT,
  # but the sweep evicts by RELEVANCE — so a file of 40 recent, all-distinct entries has
  # nothing to evict and used to re-spawn a compaction agent on every single run. Measured:
  # one sweep took 42 to 36 with zero dead-path and zero stale evictions, and four new
  # entries re-armed it within the same run. Storing the post-sweep count makes the cost
  # scale with actual growth instead of with the threshold being crossed once.
  learnings_swept_at=$(sed -n 's/^<!-- swept: \([0-9]\{1,\}\) -->$/\1/p' "$lf" 2>/dev/null | tail -1)
fi

today=$(date +%F)

diffstat=""
changed_lines=0
# set -u: the JSON below reads all four unconditionally, so they must exist even when
# base-branch resolution failed and the sizing block never ran.
semantic_lines=0
sizing_excluded=""
gen=""
# Lockfiles at any depth. A dependency bump is a real change, but its line count is
# noise: a one-line version edit regenerates thousands of lines, which dragged every
# bump out of the fast path into a six-agent fan-out with nothing to read. Supply-chain
# risk is covered by the Step 4a analyzers (gitleaks/semgrep/govulncheck), not by size.
LOCKFILES="pnpm-lock.yaml package-lock.json npm-shrinkwrap.json yarn.lock Cargo.lock
poetry.lock uv.lock Pipfile.lock Gemfile.lock composer.lock go.sum mix.lock pubspec.lock"
if [ -n "$base_branch" ]; then
  range="origin/$base_branch...HEAD"
  diffstat=$(git diff --stat "$range" 2>/dev/null || true)
  # No `|| echo 0` here: awk already prints 0 on empty input, and under `pipefail` a
  # failing git made BOTH fire — awk's 0 plus the fallback's 0 — so the value became the
  # string "0\n0", which int() refused. context.sh then exited 1 with no stdout, and
  # because Step 1 redirects into review-loop-context.json the redirect had already
  # truncated the previous valid file to 0 bytes. Reachable whenever `origin/<base>` is
  # absent locally: a single-branch clone, a pruned ref, or a best-effort fetch that
  # failed (offline, expired auth, VPN).
  changed_lines=$(git diff --numstat "$range" 2>/dev/null \
    | awk '{a+=$1; d+=$2} END {print a+d+0}')

  # Exclude pathspec: lockfiles, plus whatever .gitattributes marks linguist-generated —
  # the one declarative, repo-owned marker for generated files. Guessing from path names
  # would silently drop hand-written code that happens to live under `dist/`.
  # No positive pathspec: an exclude-only list already means "everything but these". A
  # `.` here was repo-relative only when run from the repo root — from a subdirectory it
  # scoped the semantic count to that subtree while changed_lines stayed repo-wide, and
  # the shortfall was then reported as excluded lockfiles that did not exist. Measured:
  # 501 changed lines read as semantic 1 from `docs/`, taking the fast path.
  set -- "$range" --
  for f in $LOCKFILES; do set -- "$@" ":(exclude,glob)**/$f" ":(exclude,literal)$f"; done
  gen=$(git diff --name-only "$range" 2>/dev/null \
    | git check-attr --stdin linguist-generated 2>/dev/null \
    | sed -n 's/: linguist-generated: set$//p' || true)
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    # literal: a generated path holding glob metacharacters (`app/[id]/page.tsx`, routine
    # in Next.js and SvelteKit) would otherwise exclude more files than the one named.
    set -- "$@" ":(exclude,literal)$g"
  done <<EOF
$gen
EOF

  # Semantic size, measured per file. `-w` is right for a formatter run, and WRONG where
  # indentation is syntax: a one-line dedent moving a call out of an `if user.is_test:`
  # guard is a control-flow change that `-w` scores 0. That read as "0 lines of review
  # surface", took the fast path, and skipped the security review along with agents
  # #7-#11. So `-w` applies only to files where whitespace cannot carry meaning; for the
  # rest the raw count stands. (A pure rename already counts 0 in --numstat, so it needs
  # no handling.)
  sizing=$(GEN="$gen" RAW_TOTAL="$changed_lines" python3 -c '
import os, subprocess, sys

# Indentation is syntax in these, so a whitespace-blind diff can hide control flow.
INDENT = {".py", ".pyi", ".yml", ".yaml", ".hs", ".nim", ".elm", ".coffee", ".sass",
          ".styl", ".slim", ".haml", ".pug", ".jade", ".cr", ".mk", ".make",
          # Indentation defines list nesting and code blocks in markdown, and step
          # grouping in Gherkin.
          ".md", ".markdown", ".feature"}
# Lowercased, since indent_sensitive() lowercases before matching. Recipe lines in every
# make dialect are tab-significant, and automake/include fragments are the same language.
INDENT_NAMES = {"makefile", "gnumakefile", "makefile.am", "makefile.in", "gnumakefile.am"}
INDENT_STEMS = {"makefile", "gnumakefile"}


def per_file(*flags):
    out = subprocess.run(["git", "diff", "--numstat", *flags, *sys.argv[1:]],
                         capture_output=True, text=True).stdout
    acc = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            # Binary files report "-" for both counts.
            a, d = (0 if x == "-" else int(x) for x in parts[:2])
            acc[parts[2]] = a + d
    return acc


def indent_sensitive(path):
    # Every suffix, lowercased — not just the last, and not case-sensitively. Checking only
    # the final extension sent `values.yml.j2`, `main.py.j2` and `Up.PY` down the -w path
    # and scored their indentation changes 0, which is the hole this function exists to
    # close, one naming convention over. Measured: a dedent in each of app.py, Makefile.am
    # and Up.PY reported semantic 2 of raw 6 and read as fast-path eligible.
    name = path.rsplit("/", 1)[-1].lower()
    if name in INDENT_NAMES or name.split(".")[0] in INDENT_STEMS:
        return True
    return any(f".{part}" in INDENT for part in name.split(".")[1:])


raw, blind = per_file(), per_file("-w")
kept = sum(raw.values())
semantic = sum(raw[f] if indent_sensitive(f) else blind.get(f, 0) for f in raw)

# Say what was dropped and by how much. A sizing decision nobody can audit is the
# silent-skip problem one level down: a smaller number buys a cheaper review.
raw_total = int(os.environ.get("RAW_TOTAL") or 0)
gen = [g for g in os.environ.get("GEN", "").splitlines() if g.strip()]
out = []
if raw_total - kept > 0:
    out.append(f"{raw_total - kept} line(s) in lockfiles or generated files")
if kept - semantic > 0:
    out.append(f"{kept - semantic} whitespace-only line(s), indentation-sensitive files excepted")
if gen:
    out.append("generated per .gitattributes: " + ", ".join(gen))
print(kept)
print(semantic)
print("; ".join(out))
' "$@" 2>/dev/null) || sizing=""
  kept_raw=$(printf '%s\n' "$sizing" | sed -n 1p)
  semantic_lines=$(printf '%s\n' "$sizing" | sed -n 2p)
  sizing_excluded=$(printf '%s\n' "$sizing" | sed -n 3p)
  # Fail toward MORE review. A helper that produced nothing used to leave semantic_lines
  # empty, which every downstream threshold read as 0 — the smallest possible number
  # buying the cheapest possible review. Fall back to the raw count instead.
  case "$kept_raw" in ''|*[!0-9]*) kept_raw=$changed_lines ;; esac
  case "$semantic_lines" in
    ''|*[!0-9]*) semantic_lines=$changed_lines
                 sizing_excluded="sizing helper produced no count; using the raw total" ;;
  esac
fi

BASE_BRANCH="$base_branch" LEARNINGS="$learnings" \
DIFFSTAT="$diffstat" CHANGED_LINES="$changed_lines" TODAY="$today" \
SEMANTIC_LINES="$semantic_lines" SIZING_EXCLUDED="$sizing_excluded" \
LEARN_ENTRIES="$learnings_entries" LEARN_SWEPT_AT="${learnings_swept_at:-}" python3 - <<'PY'
import json, os, re, pathlib

def pkg_scripts():
    p = pathlib.Path("package.json")
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text()).get("scripts", {}) or {}
    except Exception:
        return {}

scripts = pkg_scripts()
test_cmd = lint_cmd = None
lint_fix = False

# test command
if "test" in scripts:
    test_cmd = "npm test"
elif pathlib.Path("pyproject.toml").exists() or pathlib.Path("pytest.ini").exists():
    test_cmd = "pytest"
elif pathlib.Path("Cargo.toml").exists():
    test_cmd = "cargo test"
elif pathlib.Path("Makefile").exists() and re.search(r'^test:', pathlib.Path("Makefile").read_text(), re.M):
    test_cmd = "make test"

# lint command (+ whether it can autofix)
if "lint:fix" in scripts:
    lint_cmd, lint_fix = "npm run lint:fix", True
elif "lint" in scripts:
    lint_cmd = "npm run lint"
    lint_fix = "--fix" in scripts["lint"]
elif pathlib.Path("ruff.toml").exists() or pathlib.Path(".ruff.toml").exists():
    lint_cmd, lint_fix = "ruff check --fix", True
elif list(pathlib.Path(".").glob(".eslintrc*")):
    lint_cmd, lint_fix = "eslint --fix", True
elif pathlib.Path(".rubocop.yml").exists():
    lint_cmd, lint_fix = "rubocop -A", True

changed = int(os.environ.get("CHANGED_LINES") or 0)
semantic = int(os.environ.get("SEMANTIC_LINES") or 0)
learn_entries = int(os.environ.get("LEARN_ENTRIES") or 0)
LEARN_COMPACTION_THRESHOLD = 40  # sweep before the ~50-entry cap so it self-heals early
# Re-sweeping needs real GROWTH since the last sweep, not just being over the threshold.
# The sweep evicts by relevance, so a file already swept to 36 has nothing new to drop at
# 37 — and re-running it every run is a compaction agent per run for no evictions.
LEARN_REGROWTH = 8
swept_at = os.environ.get("LEARN_SWEPT_AT") or ""
swept_at = int(swept_at) if swept_at.isdigit() else None
print(json.dumps({
    "base_branch": os.environ["BASE_BRANCH"] or None,
    "test_cmd": test_cmd,
    "lint_cmd": lint_cmd,
    "lint_fix": lint_fix,
    "learnings": os.environ.get("LEARNINGS") or None,
    "learnings_entries": learn_entries,
    "learnings_compaction_due": (
        learn_entries >= LEARN_COMPACTION_THRESHOLD
        and (swept_at is None or learn_entries >= swept_at + LEARN_REGROWTH)),
    # So a reader can tell "not due" from "never swept".
    "learnings_swept_at": swept_at,
    "today": os.environ.get("TODAY"),
    "diff_stat": os.environ.get("DIFFSTAT") or None,
    "changed_lines": changed,
    # Raw above, review surface below. The fast path keys on the semantic count so a
    # formatter run or a lockfile regeneration stops dragging a trivial change into a
    # six-agent fan-out — and `sizing_excluded` says what was dropped.
    "semantic_lines": semantic,
    "sizing_excluded": os.environ.get("SIZING_EXCLUDED") or None,
    # `0 < changed` asks "is there a diff at all", which is a question about the raw
    # count; `semantic < 30` asks how much of it is review surface. Keying both to
    # semantic made a PURE reformatting ineligible — semantic 0 fails `0 <` — which is
    # exactly the change this sizing exists to route to the fast path.
    "fast_path_eligible_by_size": 0 < changed and semantic < 30,
}, indent=2))
PY
