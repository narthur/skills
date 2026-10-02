#!/bin/bash
# Semantic sizing decides whether a change gets a 6-agent fan-out or one reviewer, so
# its failure mode is under-counting: a smaller number buys a cheaper review. Every
# check here is a case where an exclusion must NOT happen, or must happen and be
# reported. Run against purpose-built repos, never the live one.
#   ./context-sizing.test.sh
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/context.sh"
fails=0
ok() { echo "  ok  $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ctx-sizing.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
[ "$TMP" != "/" ] && [ -d "$TMP" ] || { echo "setup failed: bad temp dir"; exit 1; }

# A repo with an `origin` the script can resolve a base branch from. context.sh fetches,
# so origin must be a real local path, not a URL.
# core.hooksPath=/dev/null: this machine has a global hooks dir whose pre-commit runs a
# secret scanner over the network. In a throwaway repo that fails slowly, the commit
# never lands, and the push then dies on a branch that was never created — so the
# fixture silently tests nothing. Every git call in a fixture goes through here.
g() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=t@t -c user.name=t "$@"; }
newrepo() {
	local up="$TMP/$1.up" wt="$TMP/$1"
	g init -q --bare "$up"
	g init -q "$wt"
	: > "$wt/seed"; g -C "$wt" add -A; g -C "$wt" commit -qm seed
	g -C "$wt" branch -M main
	g -C "$wt" remote add origin "$up"; g -C "$wt" push -q -u origin main
	g -C "$wt" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
	# Prove the fixture is sound: without an origin/main the script cannot resolve a
	# base branch and every sizing number below would be a vacuous 0.
	g -C "$wt" rev-parse --verify -q origin/main >/dev/null \
		|| { echo "setup failed: $1 has no origin/main"; exit 1; }
	echo "$wt"
}
# field <repo> <key>
field() { (cd "$1" && "$SCRIPT" 2>/dev/null) | python3 -c 'import json,sys;print(json.load(sys.stdin).get(sys.argv[1]))' "$2"; }

# --- whitespace-only reformatting is not review surface, but IS reported.
# --- Deliberately a .js file: this fixture used to reindent a .py file, where
# --- indentation IS syntax, so it was asserting the bug the next case now pins.
r=$(newrepo ws)
printf 'function f(x) {\n  if (x) {\n    return 1;\n  }\n}\n' > "$r/a.js"
g -C "$r" add -A && g -C "$r" commit -qm add
g -C "$r" push -q origin main
printf 'function f(x) {\n      if (x) {\n          return 1;\n      }\n}\n' > "$r/a.js"
g -C "$r" add -A && g -C "$r" commit -qm reindent
raw=$(field "$r" changed_lines); sem=$(field "$r" semantic_lines); exc=$(field "$r" sizing_excluded)
[ "$raw" -gt 0 ] && ok "a reindent still has a raw line count ($raw)" || bad "a reindent still has a raw line count (got: $raw)"
[ "$sem" = "0" ] && ok "a reindent has no semantic lines" || bad "a reindent has no semantic lines (got: $sem)"
[ "$(field "$r" fast_path_eligible_by_size)" = "True" ] && ok "a reindent is fast-path eligible" || bad "a reindent is fast-path eligible"
grep -q 'whitespace-only' <<<"$exc" && ok "and the exclusion is reported, not silent" || bad "and the exclusion is reported, not silent (got: $exc)"

# --- THE OTHER CASE THAT MUST NOT BE EXCLUDED: where indentation IS syntax, a diff made
# --- entirely of whitespace can move a call out of a guard. `git diff -w` scores that 0,
# --- which read as "0 lines of review surface", took the fast path, and skipped the
# --- security review along with agents #7-#11. Measured before the fix: semantic 0.
for ext in py yaml; do
	r=$(newrepo "dedent-$ext")
	case $ext in
		# Whitespace-ONLY on purpose: the whole point is that `git diff -w` scores these 0.
		# An earlier version also ADDED a line, which made -w score 1 and let `sem > 0`
		# pass under the restored bug.
		py)   before='if user.is_test:\n    log(user)\n    stripe.charge(user, amount)\n'
		      after='if user.is_test:\n    log(user)\nstripe.charge(user, amount)\n' ;;
		yaml) before='prod:\n  debug: true\n  public: true\n'
		      after='prod:\n  debug: true\npublic: true\n' ;;
	esac
	printf '%b' "$before" > "$r/a.$ext"
	g -C "$r" add -A && g -C "$r" commit -qm add && g -C "$r" push -q origin main
	printf '%b' "$after" > "$r/a.$ext"
	g -C "$r" add -A && g -C "$r" commit -qm dedent
	sem=$(field "$r" semantic_lines); raw=$(field "$r" changed_lines)
	[ "$sem" -gt 0 ] && ok ".$ext: an indentation change that moves control flow counts ($sem)" \
		|| bad ".$ext: an indentation change that moves control flow counts (got: $sem of $raw raw)"
	[ "$sem" = "$raw" ] && ok ".$ext: and counts in full, not discounted as whitespace" \
		|| bad ".$ext: and counts in full, not discounted as whitespace (sem $sem, raw $raw)"
done

# --- Run from a subdirectory, the two counts must still measure the same tree. A `.`
# --- pathspec made semantic_lines subtree-scoped while changed_lines stayed repo-wide,
# --- and the shortfall was reported as excluded lockfiles that did not exist: measured,
# --- a 501-line change read as semantic 1 from `docs/` and took the fast path.
r=$(newrepo subdir)
mkdir -p "$r/docs" "$r/src"
printf 'x\n' > "$r/docs/a.md"; printf 'y\n' > "$r/src/b.js"
g -C "$r" add -A && g -C "$r" commit -qm add && g -C "$r" push -q origin main
python3 -c "import io; io.open('$r/src/b.js','w').write(''.join(f'const v{i} = {i};\n' for i in range(50)))"
printf 'x\nmore\n' > "$r/docs/a.md"
g -C "$r" add -A && g -C "$r" commit -qm edit
root_sem=$(field "$r" semantic_lines)
sub_sem=$(cd "$r/docs" && "$SCRIPT" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["semantic_lines"])')
[ "$sub_sem" = "$root_sem" ] && ok "sizing from a subdirectory matches the repo root ($sub_sem)" \
	|| bad "sizing from a subdirectory matches the repo root (root $root_sem, docs/ $sub_sem)"
[ "$sub_sem" -ge 50 ] && ok "and still sees the whole change from there" \
	|| bad "and still sees the whole change from there (got: $sub_sem)"

# --- a lockfile regeneration is excluded; the real edit beside it is not
r=$(newrepo lock)
printf 'v: 1\n' > "$r/pnpm-lock.yaml"; printf 'x = 1\n' > "$r/a.py"
g -C "$r" add -A && g -C "$r" commit -qm add && g -C "$r" push -q origin main
python3 -c "
import io
io.open('$r/pnpm-lock.yaml','w').write(''.join(f'dep{i}: {i}\n' for i in range(400)))
io.open('$r/a.py','w').write('x = 2\n')"
g -C "$r" add -A && g -C "$r" commit -qm bump
raw=$(field "$r" changed_lines); sem=$(field "$r" semantic_lines)
[ "$raw" -gt 300 ] && ok "a lockfile bump has a large raw count ($raw)" || bad "a lockfile bump has a large raw count (got: $raw)"
[ "$sem" -le 4 ] && ok "but only the real edit counts semantically ($sem)" || bad "but only the real edit counts semantically (got: $sem)"
grep -q 'lockfile' <<<"$(field "$r" sizing_excluded)" && ok "and the lockfile exclusion is reported" || bad "and the lockfile exclusion is reported"
# The only fixture that ASSERTS the flag with counts straddling the 30-line threshold, so
# it is the only one that can tell keying on semantic from keying on raw. (The generated-file
# fixture below straddles it too — raw 51, semantic 0 — but never asserts the flag.) Without
# this line, mutating `semantic < 30` to `changed < 30` passed the entire suite.
[ "$(field "$r" fast_path_eligible_by_size)" = "True" ] && ok "and the fast path keys on semantic, not raw" \
	|| bad "and the fast path keys on semantic, not raw (raw $raw, sem $sem)"

# --- THE CASE THAT MUST NOT BE EXCLUDED: real logic, no whitespace trick
r=$(newrepo real)
printf 'x = 1\n' > "$r/a.py"; g -C "$r" add -A && g -C "$r" commit -qm add && g -C "$r" push -q origin main
python3 -c "import io; io.open('$r/a.py','w').write(''.join(f'line{i} = {i}\n' for i in range(60)))"
g -C "$r" add -A && g -C "$r" commit -qm real
sem=$(field "$r" semantic_lines)
[ "$sem" -ge 60 ] && ok "60 real lines count as 60 ($sem)" || bad "60 real lines count as 60 (got: $sem)"
[ "$(field "$r" fast_path_eligible_by_size)" = "False" ] && ok "and are not fast-path eligible" || bad "and are not fast-path eligible"

# --- a hand-written file under a generated-looking path is NOT excluded without the
# --- .gitattributes marker. Guessing from path names would drop real code.
r=$(newrepo distpath)
mkdir -p "$r/dist"; printf 'x = 1\n' > "$r/dist/hand.py"
g -C "$r" add -A && g -C "$r" commit -qm add && g -C "$r" push -q origin main
python3 -c "import io; io.open('$r/dist/hand.py','w').write(''.join(f'l{i} = {i}\n' for i in range(50)))"
g -C "$r" add -A && g -C "$r" commit -qm edit
sem=$(field "$r" semantic_lines)
[ "$sem" -ge 50 ] && ok "a dist/ path is not excluded without the gitattributes marker ($sem)" \
	|| bad "a dist/ path is not excluded without the gitattributes marker (got: $sem)"

# --- declared linguist-generated IS excluded, and named
r=$(newrepo gen)
printf 'g.txt linguist-generated\n' > "$r/.gitattributes"; printf 'a\n' > "$r/g.txt"
g -C "$r" add -A && g -C "$r" commit -qm add && g -C "$r" push -q origin main
python3 -c "import io; io.open('$r/g.txt','w').write(''.join(f'gen{i}\n' for i in range(50)))"
g -C "$r" add -A && g -C "$r" commit -qm regen
sem=$(field "$r" semantic_lines); exc=$(field "$r" sizing_excluded)
[ "$sem" = "0" ] && ok "a declared generated file has no semantic lines" || bad "a declared generated file has no semantic lines (got: $sem)"
grep -q 'g.txt' <<<"$exc" && ok "and is named in the exclusions" || bad "and is named in the exclusions (got: $exc)"

# --- no base branch: the script must still emit valid JSON with zeroed sizing rather
# --- than dying under set -u on a variable the sizing block never reached.
plain="$TMP/nobase"; g init -q "$plain"
out=$(cd "$plain" && "$SCRIPT" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$out" \
	&& ok "no base branch still emits valid JSON" || bad "no base branch still emits valid JSON"
[ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["semantic_lines"])' <<<"$out")" = "0" ] \
	&& ok "and zeroes the sizing fields" || bad "and zeroes the sizing fields"

# --- a base branch that resolves while `origin/<base>` is absent locally: a single-branch
# --- clone, a pruned ref, or a best-effort fetch that failed (offline, expired auth, VPN).
# --- Under `pipefail` both awk's own 0 and the `|| echo 0` fallback fired, making the
# --- count the string "0\\n0"; int() refused it, context.sh exited 1 with no stdout, and
# --- because Step 1 redirects into review-loop-context.json the redirect had already
# --- truncated the previous valid file to 0 bytes.
r=$(newrepo noref)
printf 'const a = 1;\n' > "$r/a.js"
g -C "$r" add -A && g -C "$r" commit -qm add && g -C "$r" push -q origin main
printf 'const a = 2;\n' > "$r/a.js"
g -C "$r" add -A && g -C "$r" commit -qm edit
# origin/HEAD is a local symbolic ref, so base_branch still resolves to `main` while the
# ref it names is gone. Pointing origin at a path that does not exist matters: without it
# context.sh's own best-effort `git fetch origin main` recreates the ref and the fixture
# never reaches the failing-git path — the check passed under the restored bug.
g -C "$r" update-ref -d refs/remotes/origin/main
g -C "$r" remote set-url origin "$TMP/gone.git"
[ -z "$(g -C "$r" rev-parse --verify -q origin/main || true)" ] \
	|| { echo "setup failed: noref fixture still has origin/main"; exit 1; }
out=$(cd "$r" && "$SCRIPT" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$out" >/dev/null \
	&& ok "a missing origin/<base> ref still emits valid JSON" \
	|| bad "a missing origin/<base> ref still emits valid JSON (rc=$rc)"

# --- a learnings file that exists with NO entries. `grep -c` prints 0 and exits 1, so the
# --- `|| echo 0` fallback fired too and the count became the string "0\\n0" — the same shape
# --- as the numstat case above, in the one place the first fix missed.
r=$(newrepo emptylearn)
printf 'const a = 1;\\n' > "$r/a.js"
g -C "$r" add -A && g -C "$r" commit -qm add && g -C "$r" push -q origin main
printf 'const a = 2;\\n' > "$r/a.js"
g -C "$r" add -A && g -C "$r" commit -qm edit
mkdir -p "$r/.git/info"
printf '# Review-loop learnings\\n\\nNo entries yet.\\n' > "$r/.git/info/review-loop-learnings.md"
out=$(cd "$r" && "$SCRIPT" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$out" >/dev/null \
	&& ok "a learnings file with no entries still emits valid JSON" \
	|| bad "a learnings file with no entries still emits valid JSON (rc=$rc)"
[ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["learnings_entries"])' <<<"$out")" = "0" ] \
	&& ok "and counts zero entries" || bad "and counts zero entries"

# --- an indentation-sensitive file whose extension is not the LAST one, or is uppercase,
# --- or is a make fragment: all previously fell through to -w and scored 0.
# One repo per file so a failure names the rule that broke: the suffix walk (.yml.j2), the
# make-name table (Makefile.am), and the case fold (Up.PY) are three separate branches.
# printf '%b' and a real tab, deliberately: the previous version used doubled backslashes
# inside a generated patch and wrote LITERAL "\n" text — 22 bytes, no newlines, no
# indentation at all — so two of the three branches had no test and deleting either left
# every suite green.
TAB=$'\t'
for case in yml.j2 Makefile.am Up.PY; do
	r=$(newrepo "indent-$case")
	case $case in
		yml.j2)      f="values.yml.j2"
		             before='prod:\n  debug: true\n  public: true\n'
		             after='prod:\n  debug: true\npublic: true\n' ;;
		Makefile.am) f="Makefile.am"
		             before="all:\n${TAB}cc -o x x.c\n${TAB}strip x\n"
		             after="all:\n${TAB}cc -o x x.c\nstrip x\n" ;;
		Up.PY)       f="Up.PY"
		             before='if t:\n    log(u)\n    charge(u)\n'
		             after='if t:\n    log(u)\ncharge(u)\n' ;;
	esac
	printf '%b' "$before" > "$r/$f"
	g -C "$r" add -A && g -C "$r" commit -qm add && g -C "$r" push -q origin main
	printf '%b' "$after" > "$r/$f"
	g -C "$r" add -A && g -C "$r" commit -qm dedent
	# Prove the fixture is what it claims: whitespace-only, so -w alone would score it 0.
	blind=$(g -C "$r" diff -w --numstat origin/main...HEAD | awk '{a+=$1; d+=$2} END {print a+d+0}')
	[ "$blind" = "0" ] || bad "FIXTURE $f: not whitespace-only (-w counts $blind)"
	sem=$(field "$r" semantic_lines); raw=$(field "$r" changed_lines)
	[ "$sem" = "$raw" ] && [ "$sem" -gt 0 ] \
		&& ok "$f counts in full, not discounted as whitespace ($sem)" \
		|| bad "$f counts in full, not discounted as whitespace (sem $sem, raw $raw)"
done

# --- the fail-toward-MORE-review fallback. With the sizing helper producing nothing,
# --- semantic_lines must fall back to the raw count, NOT to 0 — 0 is the smallest possible
# --- number and buys the cheapest possible review. Nothing exercised this, so the guard
# --- could be removed with all ten suites green. Forced by making python3 unavailable to
# --- the helper only, via a PATH stub that fails for the sizing call.
r=$(newrepo helperfail)
python3 -c "import io; io.open('$r/a.js','w').write(''.join(f'const v{i} = {i};\n' for i in range(50)))"
g -C "$r" add -A && g -C "$r" commit -qm add && g -C "$r" push -q origin main
python3 -c "import io; io.open('$r/a.js','w').write(''.join(f'const w{i} = {i};\n' for i in range(50)))"
g -C "$r" add -A && g -C "$r" commit -qm edit
stub="$TMP/stubbin"; mkdir -p "$stub"
# Fails ONLY for the sizing helper (which passes -c plus pathspec args); the final heredoc
# call reads from stdin and must still work, or the script emits no JSON at all.
cat > "$stub/python3" <<'STUB'
#!/bin/sh
case "$*" in
	*"RAW_TOTAL"*|*exclude*) exit 1 ;;
esac
exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" TMPDIR="$TMPDIR" \
	BASE_BRANCH="$BASE_BRANCH" LEARNINGS="$LEARNINGS" DIFFSTAT="$DIFFSTAT" \
	CHANGED_LINES="$CHANGED_LINES" TODAY="$TODAY" SEMANTIC_LINES="$SEMANTIC_LINES" \
	SIZING_EXCLUDED="$SIZING_EXCLUDED" LEARN_ENTRIES="$LEARN_ENTRIES" \
	/usr/bin/python3 "$@"
STUB
chmod +x "$stub/python3"
out=$(cd "$r" && PATH="$stub:$PATH" "$SCRIPT" 2>/dev/null)
if python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$out" >/dev/null 2>&1; then
	sem=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["semantic_lines"])' <<<"$out")
	raw=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["changed_lines"])' <<<"$out")
	[ "$sem" = "$raw" ] && [ "$sem" -gt 0 ] \
		&& ok "a failed sizing helper falls back to the raw count, not 0 ($sem)" \
		|| bad "a failed sizing helper falls back to the raw count, not 0 (sem $sem, raw $raw)"
	grep -q 'sizing helper produced no count' <<<"$out" \
		&& ok "and says the count came from the raw total" \
		|| bad "and says the count came from the raw total (got: $(python3 -c 'import json,sys; print(json.load(sys.stdin)["sizing_excluded"])' <<<"$out"))"
else
	# The stub could not keep the outer python working; say so rather than passing silently.
	bad "a failed sizing helper falls back to the raw count, not 0 (fixture could not run)"
fi

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit "$fails"
