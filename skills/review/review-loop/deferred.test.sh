#!/bin/bash
# deferred.py decides when a deferred finding comes back. Its failure mode is a
# deferral that is right today and silently permanent, so every check below is about
# something re-surfacing — or about an entry that never can, being named.
#   ./deferred.test.sh
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/deferred.py"
fails=0
checks=0
ok() { echo "  ok  $1"; checks=$((checks + 1)); }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); checks=$((checks + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/deferred-test.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
[ "$TMP" != "/" ] && [ -d "$TMP" ] || { echo "setup failed: bad temp dir"; exit 1; }

# core.hooksPath=/dev/null: this machine's global pre-commit hook makes a network call
# that fails slowly, which would leave the commits unmade and every check below vacuous.
g() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=t@t -c user.name=t "$@"; }
repo="$TMP/r"; g init -q "$repo"
mkdir -p "$repo/src"
printf 'export type Sketch = { draw(): void }\n' > "$repo/src/types.ts"
printf 'other\n' > "$repo/src/unrelated.ts"
g -C "$repo" add -A; g -C "$repo" commit -qm base
pin=$(g -C "$repo" rev-parse --short HEAD)
mkdir -p "$repo/.git/info"
write() { printf '%s\n' "$1" > "$repo/.git/info/review-loop-deferred.md"; }
field() { (cd "$repo" && python3 "$SCRIPT") | python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin)[sys.argv[1]]))" "$1"; }

# --- a pinned deferral whose file has NOT moved stays quiet
write "- DEFERRED 2026-10-01 (run abc123abc123): async draws could overlap.
  Grounding: no async Sketch exists. [src/types.ts:1 @ $pin]
  Guard: none — would need a new test file."
[ "$(field entries)" = "1" ] && ok "the entry is counted" || bad "the entry is counted (got: $(field entries))"
[ "$(field stale)" = "[]" ] && ok "an untouched pin is not stale" || bad "an untouched pin is not stale (got: $(field stale))"
[ "$(field unpinned)" = "[]" ] && ok "and it is not reported unpinned" || bad "and it is not reported unpinned"

# --- a change to an UNRELATED file must not wake it: a deferral that cries wolf on
# --- every commit gets ignored, which is the same end state as not recording it.
printf 'other2\n' >> "$repo/src/unrelated.ts"; g -C "$repo" add -A; g -C "$repo" commit -qm unrelated
[ "$(field stale)" = "[]" ] && ok "an unrelated commit does not wake it" || bad "an unrelated commit does not wake it (got: $(field stale))"

# --- THE CASE IT EXISTS FOR: the cited file moves, so the grounding may no longer hold
printf 'export type Sketch = { draw(): void | Promise<void> }\n' > "$repo/src/types.ts"
g -C "$repo" add -A; g -C "$repo" commit -qm "allow async draws"
st=$(field stale)
[ "$st" != "[]" ] && ok "the cited file moving makes it stale" || bad "the cited file moving makes it stale"
grep -q 'src/types.ts' <<<"$st" && ok "and the stale entry names the file" || bad "and the stale entry names the file"
grep -q 'allow async draws' <<<"$st" && ok "and names the commit that moved it" || bad "and names the commit that moved it"

# --- an entry with NO pin can never go stale, so it must be named rather than counted
write "- DEFERRED 2026-10-01 (run abc123abc123): no pin here, so nothing can ever wake this.
  Grounding: nothing uses it today."
up=$(field unpinned)
[ "$up" != "[]" ] && ok "an unpinned deferral is reported" || bad "an unpinned deferral is reported"
grep -q 'no pin here' <<<"$up" && ok "and is quoted so it can be fixed" || bad "and is quoted so it can be fixed"
[ "$(field entries)" = "1" ] && ok "and still counts as an entry" || bad "and still counts as an entry"

# --- a pin on the Grounding line belongs to the DEFERRED line above it. Pairing these
# --- line-wise reported every entry unpinned, which made the signal worthless.
write "- DEFERRED 2026-10-01: first, pinned.
  Grounding: nothing async. [src/types.ts:1 @ $pin]
- DEFERRED 2026-10-01: second, not pinned.
  Grounding: nothing uses it."
[ "$(field entries)" = "2" ] && ok "two entries are two" || bad "two entries are two (got: $(field entries))"
up=$(field unpinned)
grep -q 'second, not pinned' <<<"$up" && ! grep -q 'first, pinned' <<<"$up" \
	&& ok "only the genuinely unpinned entry is named" || bad "only the genuinely unpinned entry is named (got: $up)"

# --- a pin naming no commit HERE: staleness can never be computed for it, so the entry
# --- must be named rather than passing as quiet. pins.py notes that `broken()` could be
# --- gutted to `return []` with its own selftest still green; it could also be gutted
# --- with the whole suite green, which is how this assertion came to be missing.
write "- DEFERRED 2026-10-01 (run abc123abc123): pinned to a commit that is not here.
  Grounding: nothing. [src/types.ts:1 @ 0000000]
  Guard: none."
bp=$(field broken_pins)
grep -q '0000000' <<<"$bp" && ok "a pin naming no local commit is reported broken" \
	|| bad "a pin naming no local commit is reported broken (got: $bp)"
# Guard the guard: the same shape with a resolvable sha must NOT be reported, or the
# assertion above would also pass for an implementation that called every pin broken.
write "- DEFERRED 2026-10-01 (run abc123abc123): pinned to a real commit.
  Grounding: nothing. [src/types.ts:1 @ $pin]
  Guard: none."
[ "$(field broken_pins)" = "[]" ] && ok "and a resolvable pin is not" \
	|| bad "and a resolvable pin is not (got: $(field broken_pins))"

# --- no file at all is the normal starting state, not an error
rm -f "$repo/.git/info/review-loop-deferred.md"
out=$(cd "$repo" && python3 "$SCRIPT"); rc=$?
[ "$rc" -eq 0 ] && grep -q '"exists": false' <<<"$out" && ok "no file yet is reported, not an error" || bad "no file yet is reported, not an error"

# --- outside a repo it must not crash or invent a path
out=$(cd "$TMP" && python3 "$SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "silent outside a git repo" || bad "silent outside a git repo (rc=$rc)"

echo
# An assertion that VANISHES is invisible without a count. Two ways it has happened
# here: a syntax error inside a `cond && ok || bad` list abandons the whole list so
# NEITHER branch runs, and assertions appended below this summary never execute at all
# (six did, once). shellcheck flags the idiom ~109 times across these suites and cannot
# tell a deliberate one from a broken one — this can.
#
# Raise EXPECTED_CHECKS deliberately when you add an assertion. That edit is the review
# trail, the same way the mutation-catalog floor works.
EXPECTED_CHECKS=16
if [ "$checks" -ne "$EXPECTED_CHECKS" ]; then
	echo "ran $checks checks, expected $EXPECTED_CHECKS — an assertion vanished, or one was added without raising EXPECTED_CHECKS"
	fails=$((fails + 1))
fi
[ "$fails" -eq 0 ] && echo "all checks passed ($checks checks)" || echo "$fails check(s) failed"
exit "$fails"
