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

# BOTH patch-ids empty is the dangerous case: "" = "" is true, so string equality
# alone would carry. git suppresses a root commit's diff unless --root is passed,
# so an amended first commit produces an empty id on both sides no matter how much
# the content changed. Only the -n guard stops a false carry here.
: > "$REVIEWED"; : > "$SKIPPED"
orphan="$TMP/orphan"; mkdir -p "$orphan"
git init -q "$orphan"
o() { git -C "$orphan" -c core.hooksPath=/dev/null -c user.email=t@t -c user.name=t "$@"; }
echo "first content" > "$orphan/a.txt"; o add -A; o commit -q -m root
root_old=$(o rev-parse HEAD)
echo "COMPLETELY DIFFERENT CONTENT" > "$orphan/a.txt"; o add -A; o commit -q --amend --no-edit -m root
root_new=$(o rev-parse HEAD)
[ "$root_old" != "$root_new" ] || bad "the root amend rewrote the sha"
# Confirm the premise rather than assuming it. Mirror the script's own flag — with
# --stable here and --verbatim there, this would report on ids the script never
# computes. Printed as a note, not an `ok`: both outcomes are acceptable, so it is
# not an assertion and must not inflate the pass count.
rp_old=$(o diff-tree -p --no-commit-id "$root_old" 2>/dev/null | git patch-id --verbatim 2>/dev/null | cut -d' ' -f1)
rp_new=$(o diff-tree -p --no-commit-id "$root_new" 2>/dev/null | git patch-id --verbatim 2>/dev/null | cut -d' ' -f1)
if [ -z "$rp_old" ] && [ -z "$rp_new" ]; then
	echo "  note  a root commit yields no patch-id on either side — the both-empty case is live"
else
	echo "  note  root commits do produce patch-ids on this git; the both-empty case is moot here"
fi
printf '%s\n' "$root_old" > "$REVIEWED"
(cd "$orphan" && printf '%s %s\n' "$root_old" "$root_new" | "$SCRIPT" amend 2>/dev/null)
grep -qxF "$root_new" "$REVIEWED" \
	&& bad "two empty patch-ids must never count as identical" \
	|| ok "two empty patch-ids do not carry"

# The case the script's own header names: a rebase that resolved a conflict
# produces a different patch, so the record must not carry.
: > "$REVIEWED"; : > "$SKIPPED"
cf="$TMP/conflict"; mkdir -p "$cf"
git init -q "$cf"
c() { git -C "$cf" -c core.hooksPath=/dev/null -c user.email=t@t -c user.name=t "$@"; }
printf 'line\n' > "$cf/f.txt"; c add -A; c commit -q -m base
c branch -q trunk
printf 'mine\n' > "$cf/f.txt"; c add -A; c commit -q -m mine
conf_old=$(c rev-parse HEAD)
c checkout -q trunk; printf 'theirs\n' > "$cf/f.txt"; c add -A; c commit -q -m theirs
c checkout -q -
printf '%s\n' "$conf_old" > "$REVIEWED"
c rebase trunk >/dev/null 2>&1   # conflicts
printf 'resolved differently\n' > "$cf/f.txt"; c add -A
c -c core.editor=true rebase --continue >/dev/null 2>&1
conf_new=$(c rev-parse HEAD)
(cd "$cf" && printf '%s %s\n' "$conf_old" "$conf_new" | "$SCRIPT" rebase 2>/dev/null)
grep -qxF "$conf_new" "$REVIEWED" \
	&& bad "a conflict-resolved rebase must not carry" || ok "a conflict-resolved rebase does not carry"

# The skipped side needs the same repeat no-op the reviewed side has.
: > "$REVIEWED"
printf '%s\t2026-09-30\t%s\n' "$feat_old" "docs-only" > "$SKIPPED"
(cd "$repo" && printf '%s %s\n' "$feat_old" "$feat_new" | "$SCRIPT" rebase 2>/dev/null)
n1=$(wc -l < "$SKIPPED")
(cd "$repo" && printf '%s %s\n' "$feat_old" "$feat_new" | "$SCRIPT" rebase 2>/dev/null)
[ "$(wc -l < "$SKIPPED")" -eq "$n1" ] && ok "a repeat skipped-carry is a no-op" || bad "a repeat skipped-carry is a no-op"

# An amend during a paused rebase names a sha that does not exist yet; an abort
# then makes it permanently unreachable and nothing would ever remove the record.
: > "$REVIEWED"; : > "$SKIPPED"
mid="$TMP/midrebase"; mkdir -p "$mid"
git init -q "$mid"
m() { git -C "$mid" -c core.hooksPath=/dev/null -c user.email=t@t -c user.name=t "$@"; }
echo one > "$mid/f.txt"; m add -A; m commit -q -m one
echo two >> "$mid/f.txt"; m add -A; m commit -q -m two
mid_old=$(m rev-parse HEAD)
printf '%s\n' "$mid_old" > "$REVIEWED"
# Pause a rebase, then invoke the hook the way an --amend would during it.
# A real sequence editor: `sed -i ''` behaves differently enough across platforms
# that a failure to rewrite the todo would silently leave the rebase unpaused, and
# the check would then pass without exercising anything.
cat > "$TMP/seq-editor.sh" <<'EDIT'
#!/bin/sh
todo="$1"
awk 'NR==1 && $1=="pick" { $1="edit" } { print }' "$todo" > "$todo.new" && mv "$todo.new" "$todo"
EDIT
chmod +x "$TMP/seq-editor.sh"
GIT_SEQUENCE_EDITOR="$TMP/seq-editor.sh" m rebase -i HEAD~1 >/dev/null 2>&1
paused=""
for d in rebase-merge rebase-apply; do
	pp=$(m rev-parse --path-format=absolute --git-path "$d" 2>/dev/null)
	[ -n "$pp" ] && [ -e "$pp" ] && paused=1
done
if [ -n "$paused" ]; then
	# A REAL amend with unchanged content: its patch-id matches, so every other
	# guard would let this carry. Only the in-progress-rebase check stops it —
	# which is what makes this a test of that check rather than of the others.
	# Amend the MESSAGE, not the content: patch-id ignores the message, so the
	# patch still matches and every other guard would allow the carry. (`--no-edit`
	# is flaky here — within the same second the committer date is unchanged too,
	# so git reproduces the identical sha and there is nothing to carry onto.)
	m commit -q --amend -m "two (amended mid-rebase)"
	mid_new=$(m rev-parse HEAD)
	[ "$mid_new" != "$mid_old" ] || bad "the mid-rebase amend produced a new sha"
	(cd "$mid" && printf '%s %s\n' "$mid_old" "$mid_new" | "$SCRIPT" amend 2>/dev/null)
	grep -qxF "$mid_new" "$REVIEWED" \
		&& bad "an amend during a paused rebase must not carry (rebase --abort would strand it)" \
		|| ok "an amend during a paused rebase does not carry"
	m rebase --abort >/dev/null 2>&1
else
	# A green "not exercised" is a hollow assertion; if the fixture cannot pause a
	# rebase the check is broken and should say so.
	bad "could not pause a rebase — the mid-rebase amend guard is not being exercised"
fi

# No audit row, no gate change — including when there is no python at all to
# write one. The store write must not outlive the record that explains it.
: > "$REVIEWED"; : > "$SKIPPED"
printf '%s\n' "$feat_old" > "$REVIEWED"
nopath="$TMP/nopy"; mkdir -p "$nopath"
# Everything the script needs EXCEPT python. Miss one and the script dies earlier
# for an unrelated reason, and both assertions below pass without exercising the
# python path at all — which is how the first version of this check was hollow.
for t in git grep awk sed cut head tail wc date sort mv rm basename dirname cat tr env; do
	src=$(command -v "$t" 2>/dev/null) && ln -sf "$src" "$nopath/$t"
done
# No separate fixture-soundness probe: the message grep below IS the proof the
# script reached the check, and it cannot be satisfied by incidental stderr. A
# probe asserting merely that something was printed passed when `sort` was
# dropped from the fake PATH and the script died long before the python block.
: > "$REVIEWED"; printf '%s\n' "$feat_old" > "$REVIEWED"
out=$(cd "$repo" && printf '%s %s\n' "$feat_old" "$feat_new" | PATH="$nopath" "$SCRIPT" rebase 2>&1)
grep -qxF "$feat_new" "$REVIEWED" \
	&& bad "with no python, the gate store must not change" \
	|| ok "with no python, the gate store does not change"
grep -q "cannot record the carry" <<<"$out" \
	&& ok "and it says so rather than failing silently" || bad "and it says so rather than failing silently"

# --- no runlog.py beside the script: the other half of the same hole. The audit
# --- block used to be wrapped in `if [ -f "$RUNLOG" ]`, so a partial install that
# --- shipped the shell scripts without the python ones stamped every carry with no
# --- audit row at all — and ensure-husky-gate.sh points the hook at this directory
# --- precisely so the two can be shipped apart.
lonely="$TMP/lonely"; mkdir -p "$lonely"; cp "$SCRIPT" "$lonely/carry-review.sh"
[ ! -e "$lonely/runlog.py" ] || { echo "setup failed: runlog.py must not be beside the copy"; exit 1; }
: > "$REVIEWED"; printf '%s\n' "$feat_old" > "$REVIEWED"
out=$(cd "$repo" && printf '%s %s\n' "$feat_old" "$feat_new" | "$lonely/carry-review.sh" rebase 2>&1)
grep -qxF "$feat_new" "$REVIEWED" \
	&& bad "with no runlog.py, the gate store must not change" \
	|| ok "with no runlog.py, the gate store does not change"
grep -q "cannot record the carry" <<<"$out" \
	&& ok "and it says why" || bad "and it says why"

# --- whitespace is not cosmetic: patch-id --stable strips it before hashing, so an
# --- indentation-only rewrite shared an id with the reviewed original and carried a
# --- stamp onto code the loop never saw. In Python that changes which block a
# --- statement runs in. --verbatim separates them.
ws="$TMP/ws"; mkdir -p "$ws"; (
	cd "$ws" && git init -q . && git config user.email t@t && git config user.name t
	printf 'def f(x):\n    if x:\n        a()\n' > m.py && git add -A && git commit -qm base
	printf 'def f(x):\n    if x:\n        a()\n    b()\n' > m.py && git commit -qam outside
) >/dev/null 2>&1
ws_old=$(cd "$ws" && git rev-parse HEAD)
(cd "$ws" && git reset -q --hard HEAD~1 && printf 'def f(x):
    if x:
        a()
        b()
' > m.py && git commit -qam inside) >/dev/null 2>&1
ws_new=$(cd "$ws" && git rev-parse HEAD)
# Sanity: the two commits really are indentation-only variants of each other, or
# this proves nothing about whitespace.
[ "$ws_old" != "$ws_new" ] || { echo "setup failed: the two whitespace commits are identical"; exit 1; }
: > "$REVIEWED"; printf '%s
' "$ws_old" > "$REVIEWED"
(cd "$ws" && printf '%s %s
' "$ws_old" "$ws_new" | "$SCRIPT" amend >/dev/null 2>&1)
grep -qxF "$ws_new" "$REVIEWED" \
	&& bad "an indentation-only rewrite must not carry a reviewed stamp" \
	|| ok "an indentation-only rewrite does not carry a reviewed stamp"

# Outside a work tree it must do nothing rather than error.
out=$(cd "$TMP" && printf '%s %s\n' "$feat_old" "$feat_new" | "$SCRIPT" rebase 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "silent outside a git repo" || bad "silent outside a git repo"

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit "$fails"
