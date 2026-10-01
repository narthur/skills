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

# --- whitespace-only reformatting is not review surface, but IS reported
r=$(newrepo ws)
printf 'def f(x):\n    if x:\n        return 1\n' > "$r/a.py"
g -C "$r" add -A && g -C "$r" commit -qm add
g -C "$r" push -q origin main
printf 'def f(x):\n        if x:\n                return 1\n' > "$r/a.py"
g -C "$r" add -A && g -C "$r" commit -qm reindent
raw=$(field "$r" changed_lines); sem=$(field "$r" semantic_lines); exc=$(field "$r" sizing_excluded)
[ "$raw" -gt 0 ] && ok "a reindent still has a raw line count ($raw)" || bad "a reindent still has a raw line count (got: $raw)"
[ "$sem" = "0" ] && ok "a reindent has no semantic lines" || bad "a reindent has no semantic lines (got: $sem)"
[ "$(field "$r" fast_path_eligible_by_size)" = "True" ] && ok "a reindent is fast-path eligible" || bad "a reindent is fast-path eligible"
grep -q 'whitespace-only' <<<"$exc" && ok "and the exclusion is reported, not silent" || bad "and the exclusion is reported, not silent (got: $exc)"

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

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit "$fails"
