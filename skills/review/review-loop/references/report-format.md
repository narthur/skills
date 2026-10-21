# Step 14: PR description reconcile, summary comment, and the report block

### Reconcile the PR description (clean exit, PR exists)

On a clean loop exit, if a PR exists, make the PR description **accurate and complete** for the now-final reviewed change. This is the counterpart to Step 4b: 4b captured *intended goals* for review and deliberately left the description alone; this runs *after* review converges, so describing what the change actually does is correct rather than contaminating, and it's the moment to leave the PR merge-ready.

**When it runs — only when the change is done (converged):**
- **Clean exit** (loop converged): reconcile. This is the only state where "accurate and complete" is meaningful and stable.
- **Cycle limit reached**: **skip.** The loop didn't converge — open findings still need addressing, and fixing them will change the code, so a description written now goes stale immediately and would document known-open defects as "what the change does." It's reconciled on the eventual clean re-run instead. (Mirrors the auto-push and evidence-gate gates, which likewise hold off until the change is done.)
- **Test failure short-circuit**: skip — the tree is knowingly broken.
- **No PR** (local branch): skip; nothing to reconcile.

Then:
- Compare the current description against the final diff. Update it to state the purpose, the actual behavior (including notable edge cases and any decisions the review surfaced or resolved), and — if the repo's PRs use one — the test plan.
- **Preserve author intent and structure**: fill gaps and correct drift, don't rewrite wholesale, and never delete a human's rationale.
- Edit in place with `gh pr edit <n> --body …` — a low-risk update to your own PR.
- Do this even when the auto-push is being skipped (e.g. branch is `main`): an accurate description is still worth leaving behind.

### Post the summary comment to the PR

**Use the script. Do not hand-render this.**

```bash
printf '%s\n' "<your findings narrative>" \
  | ~/.local/bin/looper pr-report --run-id <run_id> --findings-file - --post --label
```

`looper pr-report` reads the run record and renders the factual half itself — convergence,
the disclosure verbatim, every gate with planned-vs-actual and its reason, the cycle
sequence, both sizing numbers with what was excluded, the agent roster, token spend —
then appends the narrative from `--findings-file` (`-` is stdin, which looper reads only when named) unchanged. It also applies the
`review:converged|capped|halted|unknown` label.

This exists because hand-rendering this block is the most-dropped step in the skill: it
is in the friction log, and one run's summary had to be volunteered by its author
because nothing produced it. A script cannot forget a gate, cannot state a convergence
the record contradicts, and cannot lose a cycle. **Your job is the narrative — what the
agents actually found — which is the one part no script can derive.**

With no PR it writes the pending file by itself (see below), so there is nothing extra
to remember on a fresh branch. If the post fails it says so and continues; never retry.

The format it produces is documented below so you know what it covers and what your
narrative needs to add. Do not hand-render it: `looper` is required (SKILL.md Step 0), and a
report assembled from memory is the failure this command exists to prevent.

What `--post` does with it: when a PR exists for the branch, it posts the report as a PR comment, on any terminal exit (clean, cycle-limit or test-failure), and that includes fast-path and fast-path re-entry runs (Step 3b). It also keeps a local copy.

**No PR yet: defer, don't skip.** A fresh branch is pushed *after* the loop runs (the gate forces that order), so "no PR" is the normal first-branch case. `looper pr-report --post` then writes the pending file itself, at `<git-common-dir>/info/review-loop-pending-report.<run_id>.md`. Never write that file by hand: push-check reads it as proof that the report landed. Two things flush it, and both run Step 0c's procedure (post the report, run the evidence gate, reconcile the description):

(a) If you create the PR **later in this same session**, flush it immediately.

(b) Otherwise Step 0c flushes it automatically the next time the loop runs after the PR exists.

### Report format

```
review-loop complete: <N> cycle(s), <M> commits, pushed: <yes|no — reason>.
Evidence gate: <passed — existing evidence | passed — evidence captured & posted (link) | deferred — no PR yet (flushes via Step 0c) | skipped — no functional changes | blocked — <reason>>.
Measurement gate: <passed — plan posted (metric: <name>) | waived — <reason> | deferred — no PR yet (flushes via Step 0c) | skipped — <no user-facing change | repo has no measurement capability> | blocked — <gap>>.
PR description: <reconciled to final change | already accurate — no edit | deferred — no PR yet (flushes via Step 0c) | skipped — not converged (agent budget spent / test failure)>.

Cycle 1: <summary>
Cycle 2: <summary>
...

Structural proposals (Agent #7 — not applied, your call):
- Blockers: <high-value simplifications that delete a layer/branch, or file-size breaches — the things worth doing before this merges>
- Nits: <smaller tidy-ups, listed briefly — including every proposal below the always-ask floor (<40), which was never asked>
(Omit this section entirely if Agent #7 didn't run or found nothing.)

Intent questions (Agent #9 — reconciled against PR intent, not applied, your call):
- <each as a question: "intent says X; the code does Y / doesn't do Z — intended?" — ordered by plausibility × impact; mark the ones below the always-ask floor (<40) as "not asked">
(Omit entirely if Agent #9 didn't run — skipped when the change had no reviewable intent (Step 4b) — or found nothing.)

Spec conformance (Agent #11 — checked against the written spec, not applied, your call):
- MISSING: <requirement — "quoted spec line">
- UNASKED: <behaviour in the diff the spec never asked for — "quoted spec line it exceeds">
- WRONG: <requirement implemented but not satisfied — "quoted spec line">
(Omit entirely if Agent #11 didn't run — skipped when Step 4b found no written spec artifact — or found nothing. Never collapse to a count: each finding carries a quote, and the quote is the evidence.)

Auto-applied low-risk 50-79 (no ask):
- <list with one-line summary each — visible to the user since they didn't see the ask>

Security findings below the action floor (confidence < 8/10 — considered, not actioned):
- <file:line — category — one-clause description (confidence N/10)>
(One line each, never a bare count. This is the ONLY place a wrongly-dropped security finding can
surface for a non-expert reader, so it is not collapsible the way the <50 bucket below is. Omit the
section entirely only when there were none.)

Spec artifact (Step 4b): <agent brief on #N | issue #N body | path | none — #11 skipped>.
Threat model (Step 2b): <bootstrapped — N claims | updated — R re-verified, A added, D dropped | unchanged>.
Upstream security prompt (Step 2a): <in sync at claude-code X.Y.Z | DRIFT — vendored X.Y.Z, installed A.B.C; run `upstream-check.py --extract` to diff>.

Static-analysis (Step 4a): autofixed <count>; security/secret/SAST findings <resolved/surfaced>; quality residue by tool: <tool=N, …>; skipped tools: <list or none>; errored tools, NOT scanned: <tool (exit/reason), … | none>.

Pending reports with no PR (Step 0c): <path — branch, … | none>. Left in place, not deleted; also any file `record pending --all` named on stderr as unroutable.
Ledger updates owed to the main session: <run-dir file — ledger, … | none>. (Worktree-isolated runs only; see SKILL.md Step 0.)

Learnings sweep (Step 2a): <ran — dropped N (D dead-path, S stale), promoted P, now E entries | not triggered — <E> entries>.

Remaining 50-79 findings the user skipped or didn't address:
- <list>

Remaining <50 findings (low confidence, not surfaced):
- <count only, not detail>
```


## Backfilling a deferred report (Step 0c)

The deferred file ends with an HTML comment naming the `review:<convergence>` label still owed: with
no PR there was nothing to label, so on a fresh branch — the common case, since the push gate forces
loop-then-push-then-PR — the deferring run never applied it. Post the file **as it is**, because it
carries the narrative and a re-render would not (`looper pr-report` re-renders the record but reads
the narrative only from `--findings-file`, which a later session no longer has). Then apply the label by hand,
as the note says: from looper v0.2.4 it names `gh pr edit <n> --add-label review:<convergence>`.
Notes written by looper v0.2.3 or earlier suggest `looper pr-report --run-id <id> --label` instead,
which does not do this: `--label` takes effect only with `--post`, and `--post` would add a second
comment. Read only the label from those.

Reached when `~/.local/bin/looper record pending --all` lists a file **and** a PR now exists for
the branch printed beside it. `<n>` below is that branch's PR, which is not this branch's PR
unless the listed branch is the one checked out. (Pending file but still no PR for its branch →
leave it in place, continue the run, and list it in the report.)

Run each `gh` below as its own command, with nothing chained, piped or redirected onto it: `gh`
is excluded from the sandbox only when it runs alone, and inside the sandbox its TLS fails.

**A file from another branch gets steps 1 and 3 only.** Its evidence gate, measurement gate and
description reconcile belong to that branch's checkout, and its PR may already be merged; post it,
label it, delete it, and say in this run's report that those gates were not run for it.

1. Post the file's contents as a PR comment (`gh pr comment <n> --body-file <the pending file>`),
   then label it with the convergence the note names (`label review:<convergence> still owed`).
   Notes written by the retired Python name `pr-report.py` in their suggested command; read only
   the label from them. Create the label first, since `gh pr edit` will not add one the repo does
   not have, and remove the other three so two cannot stand at once:

   ```bash
   gh label create review:<convergence> --color <colour>
   ```

   ```bash
   gh pr edit <n> --add-label review:<convergence>
   ```

   ```bash
   gh pr edit <n> --remove-label review:<other>
   ```

   The create fails harmlessly when the label already exists. Run the removal once for each of
   `converged`, `capped`, `halted`, `unknown` that is not this convergence, each as its own command,
   and read a failure there as harmless only when its error says the label does not exist.

   Colours match what `looper pr-report` uses: converged `0e8a16`, capped `fbca04`, halted
   `d93f0b`, unknown `b60205`.

   From looper v0.2.9 a second line moves the risk label the same way. Either it names
   `label risk:<level> also owed` with its create and add commands, or it says `no risk label`
   because the plan's inputs cannot say, and then every `risk:*` label comes off rather than one
   left standing from an earlier run. Notes written before v0.2.9 have no risk line; leave the
   risk labels alone for those.

   ```bash
   gh label create risk:<level> --color <colour>
   ```

   ```bash
   gh pr edit <n> --add-label risk:<level>
   ```

   ```bash
   gh pr edit <n> --remove-label risk:<other>
   ```

   The removal runs once for each of `high`, `medium`, `low` that is not this level, each as its
   own command, as for the review label. For `no risk label`, there is no level to add, so only
   the removal runs, once for each of the three.

   Colours: high `d93f0b`, medium `fbca04`, low `0e8a16`.
2. This branch's file only: run the Step 13 evidence gate and the Step 13.5 measurement gate now (the branch is pushed and testable) and reconcile the PR description (Step 14), which the no-PR exit couldn't do.
3. Delete the pending file.
4. This branch's file only: if HEAD still equals the reviewed sha the deferral was recorded at (nothing changed since), this backfill **was** the reason to run — report what you posted and exit without re-reviewing. Otherwise continue into the loop normally to review the new commits.

