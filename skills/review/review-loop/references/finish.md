# Finishing a run (Step 14): reconcile, record, push

Read this at Step 14. SKILL.md carries the five-step order and the script invocations; this file
carries the rules behind them.


## 0. Close the run record

Runs on **every** terminal exit — clean, cycle-limit, test-failure, or blocked — not just a clean one. `plan.py` wrote the planned half at Step 0b; this writes the executed half. A plan with no finish is a visibly abandoned run, which is the whole point: before this existed, a dropped gate was indistinguishable from never having invoked the skill.

Give one `executed` entry per gate the plan marked `run`, each with `status` (`done` / `skipped` / `failed`) and, for anything but `done`, a reason.

**A planned gate you don't account for makes `finish` refuse and write nothing.** Every gate the plan marked `run` needs either an `executed` entry or an escalation. That refusal is the point: without it, `finish` records whatever you chose to mention, and a dropped gate is once again only as visible as you chose to make it. If a planned gate genuinely went unrun and you are recording that fact, pass `--allow-unaccounted` — the run is written, the gate is named in the record as unaccounted, and the tier becomes `partial`.

**Reasons citing precedent are rejected and nothing is written.** "It matches an existing pattern here" is not evidence the existing pattern is correct — a copied pattern carries its bugs, and the copy is the cheapest moment to catch them. State a measurable reason (size, no logic touched, no runtime change) or run the gate.

**Three statuses, and the third matters.** `done` ran. `skipped` means you chose not to run it, and that makes the run `partial`. `n/a` means there was nothing for the gate to act on — no PR exists to post a report to, the repo has no telemetry to verify — and does NOT make the run partial, because a gate that cannot apply is not a gate that was dropped. All three need a reason; for `n/a` the reason is what was absent.

**Tier:** `partial` whenever any planned agent failed or any planned gate was skipped. The PR label and the push gate both read it that way, so calling a partial run `full` launders it.

**Escalations** record where you ran *more* than the plan's floor, with why. You may escalate; you may never descend. The accumulated escalations are the signal that a threshold is set too loosely.

**Non-interactive sessions** (headless, AO worker) can't run `AskUserQuestion`. Leave ask-bucket findings unapplied, list them in the PR as open questions, and pass the count to `--asks`; inside AO also `ao report --needs-input`. Never widen auto-apply because nobody is there to ask.

## 1. Reconcile the PR description, then post the summary comment

On a clean loop exit with a PR: reconcile the description so it is accurate and complete for the
now-final reviewed change — this is the counterpart to Step 4b, which deliberately left it alone
*during* review, because describing code you are still reviewing launders a bug into intent. Then
post the report block as a PR comment.

Skip the reconcile on a cycle-limit exit or a test-failure short-circuit — that tree is not a
converged state and its description should not claim otherwise.

On **any terminal exit** with **no PR yet** the comment is **deferred**, and so is the reconcile
when the exit was clean — the reconcile itself stays clean-exit-only. Write the
report to `.git/info/review-loop-pending-report.<run_id>.md` (shape in `references/report-format.md`) so
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
to say, which is why `push-check` refuses until the disclosure is recorded. Filing it with
`record-skipped.sh` instead would be a lie in the other direction: that store means "judged beneath
the loop", and using it here corrupts the skipped-vs-reviewed ratio `review-stats.py` reports.

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
python3 ~/.claude/skills/review-loop/push-check.py --run-id <run_id> \
  --gate-state <passed|skipped|blocked> [--unresolved-skip] \
  --branch <current> --default-branch <default>
```

Pass the gate state and the branch names. **Do not pass convergence — it is read from the record**,
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

### When NOT to auto-push — the spec `push-check.py` encodes

- **The run recorded `test-failure`, `blocked` or `abandoned`.** The branch is in a known-broken
  state; do not propagate it. Read from the record's `outcome`, so a Step 9 short-circuit reaches
  the decision even though it jumps out of the loop before the cycle row is written.
- **A non-converged run whose disclosure has not been recorded.** `pr-report.py` writes the
  `disclosed` marker; until it exists for this head, the push that the disclosure is the entire
  consideration for is refused. Run `pr-report.py` first.
- **The user explicitly skipped a 50-79 finding without "remember as dismissal pattern".** That is
  an unresolved ambiguity they may still want to think about; let them push when ready.
- **The current or default branch name is unknown.** Fail closed rather than skip the
  default-branch guard.
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
