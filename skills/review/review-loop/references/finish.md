# Finishing a run (Step 14): reconcile, record, push

Read this at Step 14. SKILL.md carries the five-step order and the script invocations; this file
carries the rules behind them.


## 0. Close the run record

Runs on **every** terminal exit — clean, cycle-limit, asks-open, test-failure, or blocked — not just a clean one. `looper plan` wrote the planned half at Step 0b; this writes the executed half. A plan with no finish is a visibly abandoned run, which is the whole point: before this existed, a dropped gate was indistinguishable from never having invoked the skill.

Give one `executed` entry per gate the plan marked `run`, each with `status` (`done` / `skipped` / `failed`) and, for anything but `done`, a reason.

**`executed` records gates that have already run, and nothing else.** The order is finish → report → push-check → `record-reviewed.sh`, and it is deliberate: `push-check` refuses a run with no finish row, and the report renders the outcome and tier from it. So when the finish is written, `record_reviewed` has not run. Recording it `done` there claims a stamp that may never happen (push-check can still refuse), and one run did exactly that, with `outcome: clean` and two unresolved asks besides. Account for it as `n/a`, with the reason that it follows the push decision, whatever the run's convergence (below).

**A finish is final, and `finish` checks its own row.** It refuses, exits 1 and writes nothing for: `--escalations` that is not a list of `{"gate":"…","reason":"…"}` objects, both strings non-blank; `--outcome clean` with `--asks` above zero; `--outcome asks-open` without it; a second finish for the same run id; and any row its own readers could not decode, which it tests before appending. Before v0.2.10 an object passed as `--escalations` was written, and the unreadable row poisoned the run for `pr-report` and `push-check` for good, since a later row cannot clear it. A wrong finish is fixed by starting a new run, never by finishing again.

**A planned gate you don't account for makes `finish` refuse and write nothing.** Every gate the plan marked `run` needs either an `executed` entry or an escalation. That refusal is the point: without it, `finish` records whatever you chose to mention, and a dropped gate is once again only as visible as you chose to make it. If a planned gate genuinely went unrun and you are recording that fact, pass `--allow-unaccounted` — the run is written, the gate is named in the record as unaccounted, and the tier becomes `partial`.

**Reasons citing precedent are rejected and nothing is written.** "It matches an existing pattern here" is not evidence the existing pattern is correct — a copied pattern carries its bugs, and the copy is the cheapest moment to catch them. State a measurable reason (size, no logic touched, no runtime change) or run the gate.

**Three statuses, and the third matters.** `done` ran. `skipped` means you chose not to run it, and that makes the run `partial`. `n/a` means there was nothing for the gate to act on — no PR exists to post a report to, the repo has no telemetry to verify — and does NOT make the run partial, because a gate that cannot apply is not a gate that was dropped. All three need a reason; for `n/a` the reason is what was absent.

**`record_reviewed` on a run that did not converge is `n/a`, not `skipped`.** It is the one gate whose applicability depends on the run's own outcome: the plan marks it `run` with the reason "on clean exit", because at plan time nobody knows whether the loop will converge. When it doesn't, the stamp has still not happened at finish time: it follows the finish, on push-check's `push: true`, whatever the convergence (§2), and a capped, halted or `asks-open` run is stamped then like a converged one. So it is `n/a` with the reason that it follows the push decision, and the run's `convergence` (`capped`/`halted`/`unknown`) is what carries "not finished" to the push gate. Only a refused push (§3) leaves the tip unstamped. Recording `skipped` instead says you declined a gate you could have run, which forces `partial` on a run that actually executed the whole process, and three such runs raise the Step 0 alarm about a gate that was working correctly every time. That is not hypothetical: it is where five of the alarm's reported misses came from, none of them real.

**Tier:** `partial` whenever any planned agent failed or any planned gate was skipped. `looper record finish` derives it rather than taking your word for it, because nothing downstream enforces it: the push gate never reads the tier, and the PR label is keyed on `convergence`. What the tier reaches is the PR comment body and `looper stats`, so calling a partial run `full` launders it in the only places a human would notice — and nothing else will catch that.

**Escalations** record where you ran *more* than the plan's floor, with why. You may escalate; you may never descend. The accumulated escalations are the signal that a threshold is set too loosely.

**Non-interactive sessions** (headless, AO worker) can't run `AskUserQuestion`. Step 8b applies unchanged: acting on a recommendation never needed anyone present, and the report is where an absent user reverses it. Leave the findings Step 8b says to ask unapplied, list them in the PR as open questions, and, with the tree sound, record `--outcome asks-open` with that count as `--asks`; inside AO also `ao report --needs-input`. Never act on one of those because nobody is there to ask. Never record `blocked` for open asks on a sound tree (a Step 9 failure or a broken tree still wins; SKILL.md Step 14 says how to pick): `blocked` is a broken tree, push-check refuses it, and a refused tip is never stamped, so the run after the user's answers re-reviews the whole branch (looper #41).

### Answers after the run

A run that finished `asks-open` is closed; a finish is final, so the answers do not go into its record. The user's answer to each open ask lands wherever the conversation is: the main session, or in planner-builder, the planner. Per answer:

- **Fix** → commit the fix, then run review-loop again. When the `asks-open` run's push-check said `push: true`, its tip was stamped (§2), so the new run's delta is only the fix: the Step 3b re-entry path when it qualifies, a full run otherwise (reviewing a large delta on its own scope is looper #42).
- **Skip** → write a learnings Dismissed entry with the user's reason (`references/learnings-format.md`), so the next run does not raise it again. Nothing changed in the tree, so no new review is owed when that tip was stamped: it already passes the pre-push gate.

When push-check refused the `asks-open` run (a reason in §3 other than its outcome), its tip is unstamped: resolve that refusal first, and expect the next run to measure from the last stamp, or from the base branch when there is none.
- **Defer** → append a DEFERRED entry to the deferred ledger (SKILL.md Step 2a), with its grounding.

The PR keeps the `asks-open` run's `review:halted` label and disclosure. Re-deriving them from the answers is looper #37; until then the answers live in the learnings, the ledger, or the follow-up run's report.

## 1. Reconcile the PR description, then post the summary comment

On a clean loop exit with a PR: reconcile the description so it is accurate and complete for the
now-final reviewed change — this is the counterpart to Step 4b, which deliberately left it alone
*during* review, because describing code you are still reviewing launders a bug into intent. Then
post the report block as a PR comment.

Skip the reconcile on a cycle-limit or `asks-open` exit or a test-failure short-circuit — that tree is not a
converged state and its description should not claim otherwise.

On **any terminal exit** with **no PR yet** the comment is **deferred**, and so is the reconcile
when the exit was clean — the reconcile itself stays clean-exit-only. Write the
report to `~/.claude/review-loop/run/<run_id>/pending-report.md` (shape in `references/report-format.md`) so
Step 0c flushes them when the PR appears. The comment posts directly on any terminal exit where a
PR already exists.

## 2. Record the reviewed commit

```bash
~/.claude/skills/review-loop/record-reviewed.sh
```

On **any exit where `push-check` says `push: true`** — and **after** that decision, never before
it, so both this run's auto-push and any later *manual* push of the same HEAD pass the gate.

Recording first defeats the broken-tree block entirely and permanently: `review-gate.sh`'s only
test is `grep -qxF "$local_sha" reviewed-shas`, so a `test-failure` tip stamped before the decision
clears every later push of that commit, with no warning and no expiry. "Before the push decision"
also cannot be obeyed — the decision is what tells you whether to record.

That includes a `capped` or `halted` run. This used to read "clean exit only", which stranded
exactly the commits the disclosure mechanism exists to let through: `push-check` authorises the
push, the gate accepts only a recorded tip, and nothing was allowed to record it. A capped run
**was** reviewed — often more thoroughly than a converged one — and how far is the PR comment's job
to say, which is why `push-check` refuses until the run's report has landed. Filing it with
`record-skipped.sh` instead would be a lie in the other direction: that store means "judged beneath
the loop", and using it here corrupts the skipped-vs-reviewed ratio `looper stats` reports.

It also includes a run the session will not push itself. A planner-builder builder is told not to push; it still runs push-check and stamps on `push: true`, and the caller pushes. The stamp follows the verdict, not the push, because it is also the baseline the next run's delta is measured from (`last_reviewed_sha`). Three builder runs on one branch, each ending on open asks and none stamped, re-reviewed the whole branch every round and never converged (looper #41).

Still skip it when `push-check` says `push: false` — a recorded `test-failure`, `blocked` or
`abandoned` outcome is a broken tree, not an unfinished review, and it should not be waved through
a later push. (The gate itself is `~/.git-hooks/review-gate.sh`; it blocks pushing commits you
authored whose tip is not recorded here, bypassable with `REVIEW_GATE_BYPASS=1`.)

### The honesty rule

**`record-reviewed.sh` is this skill's completion stamp — it means the loop actually looked at this
tip.** It is called here, by the loop, after a real review pass (full loop or the Step 3b fast
path — both count).

Do **not** hand-call it to clear the pre-push gate on a change the loop never examined: that
records a review that never happened. If you make a tiny follow-up commit after a clean exit — a
comment, a doc line, a config value — there are two honest options, and hand-calling is not one:

- **Run the fast-path re-entry** (SKILL.md Step 3b). It is cheap, and if the change is genuinely
  fast-path-eligible it ends by calling `record-reviewed.sh` legitimately.
- **Record it as skipped**, if you judge it beneath even the fast path:
  `~/.claude/skills/review-loop/record-skipped.sh "<reason>"`. This clears the gate but writes a
  *distinct* state — skipped, with your reason — that never masquerades as reviewed. A reason is
  required, so the judgment is stated rather than silent.

"It's just a comment" is precisely the rationalization the gate exists to catch. Judging a change
beneath the loop is a legitimate call; making that call *silently look like a review* is not.

## 3. The push decision

```bash
~/.local/bin/looper push-check --run-id <run_id> \
  --gate-state <passed|skipped|blocked> [--unresolved-skip]
```

| exit | meaning | stdout |
| --- | --- | --- |
| 0 | push allowed | the JSON, `"push":true` |
| 3 | push refused | the JSON, `"push":false` and the `reason` |
| 1, 2 | no decision: a usage error, an unreadable store, a run id that is not plain | empty; stderr says why |

A non-zero exit never pushes, so a command chained on it with `&&` runs only on an allowed push.
Until v0.2.10 a refusal exited 0, so a plain `push-check … && git push` would push on
`push:false`. The two incidents the friction log records piped push-check through `tail`, whose
exit status hid it, and no exit code fixes that. Chaining is safe now without a pipe, but read
the JSON either way: the exit status does not carry `reason` (what a refusal needs, or that an
allowed push needs `-u origin <branch>`) or `disclose`, and `record-reviewed.sh` (section 2
above) comes between this decision and the push.

Pass the gate state. `--branch` and `--default-branch` are read from git when omitted — the
current branch, and the branch `refs/remotes/origin/HEAD` names — and a flag you pass wins. What
git cannot name stays unknown and refuses: a detached HEAD, or an origin/HEAD that was never set
(`git remote set-head origin -a` sets it). **Do not pass convergence — it is read from the record**,
derived from the `cycle` rows recorded at Step 10. `--clean-exit` is gone: it let the orchestrator
assert the answer to the only question here, and a run did record `clean` while not having
converged. A run with no cycle rows derives as *unknown*, which every consumer treats as "did not
converge", so there is no way to buy a silent push by leaving the rows out.

It checks the git facts itself — is this the default branch, is an upstream configured — and emits
`{push, reason, convergence, disclose}`. **Push only when `push` is true.**

`disclose` is non-null whenever the loop did not converge. **Put it in the PR summary verbatim.**
A capped run is allowed to push precisely because it says so; a capped run that pushes silently is
worse than one that stalls.

Use the checker rather than re-deriving the checklist: pushing to the wrong branch is the costly
mistake, and a script cannot talk itself into it.

When it says push:

`git push` — or `git push -u origin <branch>` when `reason` says the branch has no upstream yet

If the push fails (network error, branch protection, missing upstream, non-fast-forward), surface
the error verbatim in the final report and continue — do not retry, do not force.

### When NOT to auto-push — the spec `looper push-check` encodes

- **No readable row for the run id.** A wrong `-store`, a missing file, a mistyped run id or a
  run whose rows are all torn loads as an empty record. That is no evidence a run happened, so it
  blocks rather than disclosing `unknown`; stderr names the run and the store that was read.
- **A run that was never finished (no finish row).** Step 14 closes the record before it posts
  the report, so an unfinished run skipped a step and its report rendered no outcome or tier.
  Close it with `~/.local/bin/looper record finish --run-id <run_id> …` (SKILL Step 14, with an
  `--executed` entry per planned gate or `--allow-unaccounted`), re-post with
  `~/.local/bin/looper pr-report --run-id <run_id> --post </dev/null`, then ask again. A session
  that died mid-loop is different: its review stopped partway and Step 9 may never have run, so do
  not finish it as `cycle-limit` and stamp a tip the loop never finished. Close it with
  `~/.local/bin/looper record abandon --run-id <run_id> --missing '<gates you are not running>'`,
  which blocks that run id (its push-check then says "broken, not merely unfinished", which is
  expected), and review the tip with a fresh run. A finish row whose line was torn
  reads exactly like a missing one, and stderr says so; record the finish again.
- **The run recorded `test-failure`, `blocked` or `abandoned`.** The branch is in a known-broken
  state; do not propagate it. Read from the record's `outcome`, so a Step 9 short-circuit reaches
  the decision even though it jumps out of the loop before the cycle row is written.
- **A run whose report has not landed.** `looper pr-report` writes the run's marker and its
  `N cycle(s) · M agent(s)` line into every body; until a PR comment or the pending-report file
  carries both, the push is refused — on every terminal exit, converged included. Run
  `~/.local/bin/looper pr-report --run-id <run_id> --post </dev/null` first.
- **The user explicitly skipped a 50-79 finding without "remember as dismissal pattern".** A skip Step 8b made on recommendation is not one; it does not set `--unresolved-skip`. That is
  an unresolved ambiguity they may still want to think about; let them push when ready.
- **The current or default branch name is unknown** — neither passed nor readable from git (a
  detached HEAD, an unset origin/HEAD). Fail closed rather than skip the default-branch guard.
- **Branch is the repo's default branch (main/master).** Never auto-push to main; surface the
  unusual state instead.
- **The Step 13 evidence gate is blocked or hit its restart cap.** Untested (or known-broken)
  functionality does not get pushed on your say-so.
- **The Step 13.5 measurement gate is blocked or hit its restart cap.** An unmeasurable ship is a
  ship you cannot learn from, and the instrumentation belongs in this PR. (A *waived* gate is not
  blocked — that one pushes.)

When skipping the auto-push, end the report with `Next step: <reason>; push when ready.` Do not
pretend it was a clean exit.

## 4. Emit the report

The exact block — and the deferred-report file shape — is in `references/report-format.md`.
