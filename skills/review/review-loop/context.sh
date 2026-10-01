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
  learnings_entries=$(grep -c '^- ' "$lf" 2>/dev/null || echo 0)
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
  changed_lines=$(git diff --numstat "$range" 2>/dev/null \
    | awk '{a+=$1; d+=$2} END {print a+d+0}' || echo 0)

  # Exclude pathspec: lockfiles, plus whatever .gitattributes marks linguist-generated —
  # the one declarative, repo-owned marker for generated files. Guessing from path names
  # would silently drop hand-written code that happens to live under `dist/`.
  set -- "$range" -- .
  for f in $LOCKFILES; do set -- "$@" ":(exclude,glob)**/$f" ":(exclude)$f"; done
  gen=$(git diff --name-only "$range" 2>/dev/null \
    | git check-attr --stdin linguist-generated 2>/dev/null \
    | sed -n 's/: linguist-generated: set$//p' || true)
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    set -- "$@" ":(exclude)$g"
  done <<EOF
$gen
EOF

  # -w drops whitespace-only changes: a reindent or a formatter run is not review
  # surface. (A pure rename already counts 0 in --numstat, so it needs no handling.)
  semantic_lines=$(git diff -w --numstat "$@" 2>/dev/null \
    | awk '{a+=$1; d+=$2} END {print a+d+0}' || echo 0)

  # Say what was dropped and by how much. A sizing decision nobody can audit is the
  # silent-skip problem one level down: a smaller number buys a cheaper review.
  kept_raw=$(git diff --numstat "$@" 2>/dev/null | awk '{a+=$1; d+=$2} END {print a+d+0}' || echo 0)
  sizing_excluded=$(GEN="$gen" python3 -c '
import os, sys
raw, kept, sem = (int(x) for x in sys.argv[1:4])
gen = [g for g in os.environ.get("GEN", "").splitlines() if g.strip()]
out = []
if raw - kept:
    out.append(f"{raw - kept} line(s) in lockfiles or generated files")
if kept - sem:
    out.append(f"{kept - sem} whitespace-only line(s)")
if gen:
    out.append("generated per .gitattributes: " + ", ".join(gen))
print("; ".join(out))' "$changed_lines" "$kept_raw" "$semantic_lines" 2>/dev/null || true)
fi

BASE_BRANCH="$base_branch" LEARNINGS="$learnings" \
DIFFSTAT="$diffstat" CHANGED_LINES="$changed_lines" TODAY="$today" \
SEMANTIC_LINES="$semantic_lines" SIZING_EXCLUDED="$sizing_excluded" \
LEARN_ENTRIES="$learnings_entries" python3 - <<'PY'
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
print(json.dumps({
    "base_branch": os.environ["BASE_BRANCH"] or None,
    "test_cmd": test_cmd,
    "lint_cmd": lint_cmd,
    "lint_fix": lint_fix,
    "learnings": os.environ.get("LEARNINGS") or None,
    "learnings_entries": learn_entries,
    "learnings_compaction_due": learn_entries >= LEARN_COMPACTION_THRESHOLD,
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
