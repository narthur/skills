#!/bin/bash
# The carry must fire on a clean rebase and must NOT fire when the content changed.
# Getting the second half wrong would stamp "reviewed" on code no one reviewed.
#   ./carry-review.test.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 1
SCRIPT="$PWD/carry-review.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/carry-review-test.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0
ok() { echo "  ok  $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }

export HOME="$TMP/home"
export REVIEW_LOOP_RUNS="$TMP/runs.jsonl"
REVIEWED="$HOME/.claude/review-loop/reviewed-shas"
SKIPPED="$HOME/.claude/review-loop/skipped-shas"
mkdir -p "$(dirname "$REVIEWED")"

repo="$TMP/repo"; mkdir -p "$repo"
# core.hooksPath=/dev/null: the global pre-commit hook fails TLS in the sandbox.
git init -q "$repo"
g() { git -C "$repo" -c core.hooksPath=/dev/null -c user.email=t@t -c user.name=t "$@"; }

echo base > "$repo/base.txt"; g add -A; g commit -q -m base
g branch -q other
echo feature > "$repo/feature.txt"; g add -A; g commit -q -m feature
feat_old=$(g rev-parse HEAD)

# An unrelated commit on the base, so the rebase is real but conflict-free.
g checkout -q other; echo more >> "$repo/base.txt"; g add -A; g commit -q -m unrelated
g checkout -q -; g rebase -q other >/dev/null 2>&1
feat_new=$(g rev-parse HEAD)
[ "$feat_old" != "$feat_new" ] || { bad "the rebase rewrote the sha"; exit 1; }

# Nothing recorded for the old sha => nothing to carry.
(cd "$repo" && printf '%s %s\n' "$feat_old" "$feat_new" | "$SCRIPT" rebase 2>/dev/null)
[ ! -s "$REVIEWED" ] && ok "carries nothing when nothing was recorded" || bad "carries nothing when nothing was recorded"

# Reviewed, clean rebase, identical patch => carries.
printf '%s\n' "$feat_old" > "$REVIEWED"
(cd "$repo" && printf '%s %s\n' "$feat_old" "$feat_new" | "$SCRIPT" rebase 2>/dev/null)
grep -qxF "$feat_new" "$REVIEWED" && ok "a clean rebase carries a reviewed record" || bad "a clean rebase carries a reviewed record"
# The store writes compact JSON; only `runlog.py show` adds the pretty spacing.
grep -q '"outcome":"carried"' "$REVIEW_LOOP_RUNS" 2>/dev/null \
	&& ok "the carry is recorded as its own state" || bad "the carry is recorded as its own state"
grep -q "\"carried_from\":\"$feat_old\"" "$REVIEW_LOOP_RUNS" 2>/dev/null \
	&& ok "the record names what it was carried from" || bad "the record names what it was carried from"

# Running again must not duplicate.
before=$(wc -l < "$REVIEWED")
(cd "$repo" && printf '%s %s\n' "$feat_old" "$feat_new" | "$SCRIPT" rebase 2>/dev/null)
[ "$(wc -l < "$REVIEWED")" -eq "$before" ] && ok "a repeat carry is a no-op" || bad "a repeat carry is a no-op"

# CONTENT CHANGED => must NOT carry. This is the half that matters: carrying here
# would stamp "reviewed" on code nothing reviewed.
echo "amended line" >> "$repo/feature.txt"; g add -A; g commit -q --amend --no-edit
feat_amended=$(g rev-parse HEAD)
(cd "$repo" && printf '%s %s\n' "$feat_new" "$feat_amended" | "$SCRIPT" amend 2>/dev/null)
grep -qxF "$feat_amended" "$REVIEWED" \
	&& bad "changed content must not carry" || ok "changed content does not carry"

# A skipped record carries with its reason, marked as carried.
: > "$REVIEWED"
printf '%s\t2026-09-30\t%s\n' "$feat_old" "docs-only, 4 lines" > "$SKIPPED"
(cd "$repo" && printf '%s %s\n' "$feat_old" "$feat_new" | "$SCRIPT" rebase 2>/dev/null)
grep -q "^$feat_new" "$SKIPPED" && ok "a skipped record carries too" || bad "a skipped record carries too"
grep "^$feat_new" "$SKIPPED" | grep -q "docs-only, 4 lines" \
	&& ok "the original reason is preserved" || bad "the original reason is preserved"
grep "^$feat_new" "$SKIPPED" | grep -q "carried from" \
	&& ok "the carried skip says so in its reason" || bad "the carried skip says so in its reason"

# A merge commit has no single patch, so it can never be proven identical.
: > "$REVIEWED"; : > "$SKIPPED"
g checkout -q -b merger "$feat_old" 2>/dev/null || g checkout -q -b merger
g merge -q --no-ff other -m merge >/dev/null 2>&1
mrg=$(g rev-parse HEAD)
printf '%s\n' "$mrg" > "$REVIEWED"
(cd "$repo" && printf '%s %s\n' "$mrg" "$feat_new" | "$SCRIPT" rebase 2>/dev/null)
[ "$(wc -l < "$REVIEWED")" -eq 1 ] && ok "a merge commit never carries" || bad "a merge commit never carries"

# Outside a work tree it must do nothing rather than error.
out=$(cd "$TMP" && printf '%s %s\n' "$feat_old" "$feat_new" | "$SCRIPT" rebase 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "silent outside a git repo" || bad "silent outside a git repo"

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit "$fails"
