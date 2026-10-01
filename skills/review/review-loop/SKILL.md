---
name: review-loop
description: >-
  Pre-push multi-agent code review loop with auto-fix, finding scores, and per-repo learnings.
  The reviewer for this setup. Use before any push and whenever finishing or cleaning
  up a chunk of code changes — invoke it proactively without asking permission first; prefer
  running it over skipping it.
---

You are an expert code reviewer running a multi-cycle, multi-agent review-fix-commit loop on the current branch. Your job is to deliver commercial-reviewer-grade depth using Claude subagents, apply high-confidence fixes automatically, batch ambiguous fixes for user approval, and accumulate per-repo learnings over time.

**Treat yourself as the last review pass before push.** Some repos also run a PR bot such as CodeRabbit, but that is per-repo, post-push, and not something to lean on. What you miss can ship. That raises the cost of a false negative relative to a false positive: when a finding is borderline real, surface it rather than filtering it out.

## Step 0: Gather Context (scripted)

Run the context gatherer once at the start:

```bash
~/.claude/skills/review-loop/context.sh > "$(git rev-parse --git-dir)/review-loop-context.json"
cat "$(git rev-parse --git-dir)/review-loop-context.json"
```

Save it rather than reading it straight off the terminal: Step 0b needs the same JSON as a file, and re-running `context.sh` there would re-fetch and could resolve a different base.

It emits a single JSON blob and performs Steps 1–3 and the Step 3b *sizing* deterministically — workspace detection, base-branch resolution (with `git fetch`), learnings load, and test/lint/diff-size detection. Read its fields instead of re-running those steps by hand:

- `base_branch` — the resolved base; `null` means all three fallbacks failed → ask the user (Step 1)
- `test_cmd`, `lint_cmd`, `lint_fix` — detected commands (Step 3); `null` test_cmd → warn once per Step 3
- `learnings` — contents of the learnings file, or `null` (Step 2)
- `learnings_entries`, `learnings_compaction_due`, `today` — entry count, whether the staleness sweep should run (Step 2a), and today's date for the sweep's age math
- `diff_stat`, `changed_lines` — branch diff size, raw
- `semantic_lines` — the raw count minus whitespace-only changes, lockfiles, and files the repo declares `linguist-generated`. This is the **review surface**, and it is what every size threshold in this skill keys on. A pure rename already counts 0 raw, so it needs no special handling.
- `sizing_excluded` — what was dropped from the raw count and how much. Quote it whenever you cite a size: under-counting buys a cheaper review, so an unexplained smaller number is the silent-skip problem one level down.
- `fast_path_eligible_by_size` — `true` if there is a diff at all and its *semantic* size is under ~30 lines (the *size* half of Step 3b's gate; you still judge whether logic was touched)

Workspace detection and Steps 1–3 are documented in `references/context-fallback.md` — the **fallback** to consult only if the script errors or returns `null` for something you need. Don't re-run their bash by hand when the JSON already has the answer.

Then self-heal the pre-push gate for husky repos (husky's local `core.hooksPath` shadows the global hook, so those repos need a delegator):

```bash
~/.claude/skills/review-loop/ensure-husky-gate.sh
```

No-op unless this is a husky repo missing a delegator; when one is missing it drops an untracked hook handing control to the global script — `pre-push` to `~/.git-hooks/review-gate.sh`, and `post-rewrite` to this skill's `carry-review.sh`. Husky's local `core.hooksPath` shadows both. Runs before any push this session, so the gate is in place by Step 8/14.

**`post-rewrite` carries a review record across a rebase.** A rebase or amend rewrites shas, which used to invalidate a review the loop had legitimately earned. It fixes the clean case only — which is the point; `carry-review.sh`'s header measures how small that case actually is, and is the one place that measurement lives. `carry-review.sh` now moves the record onto the new sha when `git patch-id --verbatim` shows the patch itself unchanged, whitespace included — `--stable` strips whitespace before hashing, so it would have carried a stamp across an indentation-only rewrite — and records the move as its own `carried` state rather than passing it off as a direct review. A rebase that resolved a conflict produces a different patch and does not carry, which is correct: that content was never reviewed. Nothing to invoke — the hook fires on its own.

## Step 0b: Compute the review plan (scripted)

Every gate below whose trigger is a value in a script's output is computed here, not remembered. This exists because the orchestrator carries the whole procedure while also doing the review work, and the steps it drops are exactly those gates.

```bash
python3 ~/.claude/skills/review-loop/plan.py \
  --context "$(git rev-parse --git-dir)/review-loop-context.json" \
  --model <your own model id> \
  --logic yes|no --behavioral-goal yes|no --runtime-change yes|no --attacker-reachable yes|no \
  [--spec-artifact yes|no]
```

Four booleans, because they are the only inputs a script can't measure — and because free text here is where improvisation re-enters wearing a manifest. Answer them about the branch diff:

- `--logic` — does the diff change program logic (as opposed to docs, comments, config values, dependency bumps, copy)?
- `--behavioral-goal` — can the change's purpose be stated as intended *behavior*? Gates Agent #9. (Re-run this flag after Step 4b if you learn otherwise.)
- `--runtime-change` — does runtime behavior change? Gates Steps 13 and 13.5.
- `--attacker-reachable` — is any changed path attacker-reachable?

It prints the plan and writes the **planned** half of the run record, then prints the `run_id`. **Keep that `run_id`** — Step 14 needs it, and a `Stop` hook will block the session until the run is finished or explicitly abandoned.

**The plan's `tier_floor` is a floor.** You may escalate above it (record the escalation at Step 14); you may never descend. Descending is what makes the skill impossible to iterate on, because no two runs then execute the same process. You do not name a tier — the script does.

**"It already has precedent in the repo" never licenses reduced review.** Bugs pre-exist; copying a pattern propagates them; the copy is the cheapest moment to catch one. `runlog.py finish` rejects any skip or escalation reason citing precedent. State a measurable reason (size, no logic touched, no runtime change) or run the gate.

If `plan.py` prints an alarm on stderr, a gate has failed to complete three or more times across recent runs. Read it — that's the signal to fix the gate, not to log it again.

## Step 0c: Backfill a deferred PR report (triggered)

The push-gate forces the order `loop → push → create PR` for a fresh branch, so the loop almost always finishes **before** a PR exists. Step 14 defers the summary comment and evidence to `.git/info/review-loop-pending-report.md` rather than dropping them; this step flushes that once a PR appears.

```bash
test -f .git/info/review-loop-pending-report.md && gh pr view --json number -q .number 2>/dev/null
```

Nothing pending, or still no PR → continue (leave the file in place). Both present → **Read `references/report-format.md`** and follow its *Backfilling a deferred report* section.

## Step 2a: Learnings Staleness Sweep (triggered)

When Step 0 reports `learnings_compaction_due = true` (≥40 entries), run the relevance-based sweep **once here, before the review agents**, so the whole run uses the slimmed file — then skip it for the rest of the run. Otherwise skip entirely. Procedure (dead-path + stale eviction, dedup/promote, one compaction subagent): **Read `references/staleness-sweep.md`**.

Also run two cheap no-LLM checks here:

```bash
python3 ~/.claude/skills/review-loop/deferred.py
python3 ~/.claude/skills/review-loop/upstream-check.py
```

**`deferred.py` — findings whose grounding may have expired.** A reachability deferral is a
grounded judgment, not a dodge: the review happened, the finding is real, and the only claim is
that nothing exercises it *today*. The hazard is that such a deferral is right when written and
silently permanent afterwards. "No async Sketch exists, so two draws cannot overlap" stops being
true the moment someone writes the second Sketch — which is exactly when the finding matters and
when nobody remembers it exists.

- **`stale[]` is a worklist.** Each entry's cited file has moved, so re-read the grounding. It
  either still holds (re-pin to the current sha), no longer holds (the finding is live — route it
  into this run as a cycle-1 finding), or the code is gone (delete the entry). Do not leave a
  stale entry stale.
- **`unpinned[]` is a defect in the record**, not a finding. An entry with no `[file:line @ sha]`
  can never be marked stale, so it will survive the change that invalidated it. Pin it or delete it.
- Nothing stale and nothing unpinned → continue; this costs one `git log` per entry.

**To defer a finding** (Step 8a routes it here; never auto-apply a finding you are deferring),
append to `<git-common-dir>/info/review-loop-deferred.md`:

```
- DEFERRED <date> (run <run_id>): <the finding, stated as the defect it is>
  Grounding: <the specific fact that makes it unreachable today>. [<file>:<line> @ <sha>]
  Guard: <the assertion that now fails if the grounding breaks, or why none was cheap>
```

The pin goes on the file whose change would invalidate the grounding — the type, the interface,
the registry — not on the code that would break.

**Add a guard when one is cheap.** *Cheap* means expressible as an assertion inside an existing
test or check, with no new file and no new dependency. If it is cheap, just add it: a tripwire that
fails the moment the grounding breaks beats a note that something should be re-read. If it is not
cheap, weigh how bad the defect would be against the cost of adding and maintaining the guard, and
record the answer on the `Guard:` line either way — including "none, because …", so the next reader
knows it was considered rather than forgotten.

`references/security-review.md` vendors Anthropic's `/security-review` prompt, which is compiled into the Claude Code binary and so updates silently whenever Claude Code does. On `drift: true`, note it in the Step 14 report and offer once to diff (`--extract`) and reconcile — never block the run, and never auto-adopt: some departures are deliberate.

## Step 2b: Threat model — bootstrap, staleness, update

Runs **once per run, before the loop** (the artifact is repo-scoped, not cycle-scoped). Maintains `<git-common-dir>/info/review-loop-threat-model.md`, the only place repo-specific security context survives between runs. **Read `references/threat-model.md`** for the file format, the bootstrap brief, and the update brief.

```bash
python3 ~/.claude/skills/review-loop/threat-model.py
```

- **`exists: false`** → run the **bounded bootstrap** (one `sonnet` agent, hard caps: ~30 files read, ~60 lines written, four questions only). Skip entirely on a repo with no attacker-reachable surface — write one line saying so, so the next run doesn't retry.
- **`exists: true`** → run the **update agent** (one `sonnet` agent) with the script output plus this cycle's diff. `stale[]` is the exact worklist: each entry's cited file changed since its commit pin, so the claim needs re-reading and then re-pinning, rewriting, or deleting. Skip the agent entirely when `stale` is empty and the diff touches no security-relevant surface.

Every claim is **OBSERVED** (verified, carries `[file:line @ sha]`) or **INFERRED** (unverified, uncited). The consumer treats OBSERVED as fact and INFERRED as a hypothesis to check. This split exists because the user is not a security expert and cannot audit this file — it makes a wrong inference cost a redundant check rather than a missed vulnerability.

## Step 3b: Trivial-diff fast path

Before entering the main loop, check the diff size. Step 0's `context.sh` already reports this — `fast_path_eligible_by_size` is the `< ~30 semantic lines` test, and `diff_stat` shows the breakdown (fall back to `git diff --stat origin/<base_branch>...HEAD` if you don't have the JSON). If **all** of these hold, skip the 6-way fan-out and run a **single combined reviewer** instead:

- `fast_path_eligible_by_size` is true (fewer than ~30 lines of review surface — a 400-line lockfile regeneration or a whole-file reformat can qualify, and `sizing_excluded` says why), and
- no single hunk touches program logic — the diff is confined to docs, comments, config/manifest values, dependency-version bumps, or string/copy edits.

When in doubt (any logic touched, or borderline size), do NOT take the fast path — run the full loop. The fan-out's value is independent perspectives on substantial code; a typo or a version bump doesn't earn six agents plus scorers.

**Think the full loop is overkill for a diff that fails this test? Ask; don't decide.** E.g. a one-call stdlib swap plus its test. Before spawning anything, send one 🔀 AskUserQuestion: the diff stat, what logic changed, and why you think the fan-out isn't warranted. Offer "Full loop (Recommended per skill)" and "Fast path". Take the fast path only on an explicit yes, and record that approval in the report. In a headless or subagent run where you can't ask, run the full loop. Never downgrade silently.

**Fast path:** run **no conditional agents** (#7–#10) — a logic-free sub-30-line diff can't earn a structural proposal, an intent reconciliation, or the `gh` calls Agent #10 costs. Still run the Step 4a code-analysis pass (it's a deterministic subprocess, near-zero token cost, and catches secrets/SAST), then spawn **one** review subagent (`model: sonnet` — a sub-30-line, logic-free diff doesn't earn the top tier) covering the union of Agents #1 (CLAUDE.md), #2 (bugs), #4 (comments), and the security review's Stage-1 finder — pass it the diff, the learnings file, the threat model, and the style default. Score its findings with **one** batched Haiku scorer (Step 6), then run Steps 7–14 exactly as normal (auto-fix / ask / test / commit / evidence gate / push). Report it as a single fast-path cycle. If that reviewer surfaces anything that changes program logic (an applied fix that isn't doc/config/comment-only), fall back to the full loop from cycle 1 — the fast path's premise (no logic under review) no longer holds.

### Fast-path re-entry — the follow-up commit after a clean exit

You already ran the loop this session, reached a clean exit, then made a **small follow-up commit** (a comment, a doc line, a config tweak) — often to satisfy review feedback or your own polish. The pre-push gate will (correctly) block it: the tip changed, so this exact state hasn't been reviewed. **Do not** reach for `record-reviewed.sh` by hand to clear it — that stamps "reviewed" on something the loop never saw (see Step 14).

Instead, re-enter here cheaply. Diff the new commit against the last reviewed sha (`git diff <last-reviewed-sha>...HEAD`), then:

- **Fast-path-eligible** (Step 3b's test on that delta: under ~30 changed lines, no program logic) → run the fast path on the delta only: Step 4a static analysis + one combined reviewer + one scorer, then Step 14 as normal (post or defer the summary comment, `record-reviewed.sh`, push check). This is ~10 seconds and ends with a *legitimate* reviewed stamp.
- **Genuinely beneath even that** (e.g. a one-word typo fix in a comment) → `record-skipped.sh "<reason>"` (Step 14). Honest, auditable, one line.
- **The tip changed only because of a rebase or amend, with no content change** → nothing to do. The `post-rewrite` hook already carried the record by `patch-id`. Do not reach for `record-skipped.sh` to paper over a rewritten sha. If the record did not carry, treat the delta as unreviewed — usually because the patch differs, but confirm the hook is actually installed here before concluding that, since an uninstalled hook is silent in exactly the same way.
- **Touches logic, or you're unsure** → run the full loop from cycle 1 on the delta. The re-entry is a shortcut for *trivial* follow-ups, not a way to shrink review of real changes.

The point: make the honest lightweight path as cheap as the dishonest shortcut was, so there's never a reason to fake the stamp.

## Step 4: Main Loop

```
cycle = 1
max_cycles = 3

while cycle <= max_cycles:
    a. Run the code-analysis pass (Step 4a below): the code-analysis skill (--diff --fix) plus the project linter --fix if detected. Stage what changed; collect the deterministic tool findings.
    b. Run the parallel review subagents (Step 5) over this cycle's REVIEW SCOPE (see below). Each returns findings + suggested fixes. In cycle 1 only, and only if Step 4b (run once, before the loop) established a reviewable intent, also spawn Agent #9 (intent reconciliation).
       REVIEW SCOPE:
         - cycle 1: the full branch diff, `git diff origin/<base_branch>...HEAD` — nothing has been reviewed yet.
         - cycles 2+: only the changes THIS loop has made since it last reviewed, i.e. `git diff <sha-at-end-of-prev-cycle>...HEAD` (the fix commit(s) from the previous cycle). The rest of the branch was already reviewed in cycle 1; re-reviewing it re-pays the whole cost for code that didn't change. Reviewing the fix delta still catches fix-induced regressions, which is the only new risk a later cycle introduces.
       Record the current HEAD sha at the end of each cycle (Step 10) so the next cycle can diff against it.
    c. For each finding, spawn a Haiku scorer subagent (Step 6). Score 0-100.
    d. Bucket by score AND risk profile (Step 8a):
       - structural (Agent #7) or intent-reconciliation (Agent #9), ≥40 → ask-user; <40 → report-only (never auto-apply either way)
       - ≥80                              → auto-fix
       - 50-79 + low-risk                 → auto-fix (no ask)
       - 50-79 + high-risk                → ask-user
       - <50                              → skip
    e. If auto-fix bucket is empty AND the code-analysis pass made no changes and surfaced no unresolved security/secret/SAST findings → record the cycle (step j2, `--applied 0`, no `--analysis-changed`) and EXIT LOOP (clean). That zero-fix row IS the proof of convergence; skipping it because the loop is ending makes the run indistinguishable from one that ran out of budget.
    f. Apply auto-fix bucket via Edit (Step 7).
    g. If ask-user bucket is non-empty, batch them into one AskUserQuestion (Step 8b). Apply approved fixes.
    h. If test command detected, run tests (Step 9). On failure → STOP LOOP, report.
    i. Commit this cycle's changes (Step 10).
    j. Append captured learnings to .git/info/review-loop-learnings.md (Step 11), deduping against existing entries.
    j2. Record the cycle: `runlog.py cycle --run-id .. --n .. --applied .. --agents ..` (Step 10).
        EVERY cycle, including a zero-fix one — convergence is derived from these rows, and a run
        with none of them reads as "did not converge" at Step 14.
    k. cycle += 1

If cycle > max_cycles:
    Report: "Reached cycle limit (3). Remaining findings below."
    The last cycle's row (applied > 0) is what makes this derivable as `capped`/`halted` rather
    than being asserted. This no longer blocks the push — Step 14 pushes with the `disclose` line
    the checker emits. Stranding the commits only moves the decision back to the user.
```

On a clean loop exit, run the manual-testing evidence gate (Step 13) before the final report/auto-push (Step 14). If the gate's testing uncovers a real issue, fix + commit + restart the loop from cycle 1 (see Step 13).

## Step 4a: Code-analysis pass (deterministic tools)

Loop step (a). Runs at the top of every cycle, before the review agents. This is the deterministic counterpart to the LLM review — the review agents (Step 5) deliberately ignore linter/typechecker territory because this pass owns it.

**1. Run the code-analysis skill, scoped to the diff, with autofix:**

```bash
python3 ~/.claude/skills/code-analysis/code-analysis.py . --diff --fix --exit-zero
```

It detects the repo's languages/configs and runs the curated analyzer set (ESLint/Biome/oxlint, Ruff, RuboCop, Stylelint, golangci-lint, govulncheck, gitleaks, Semgrep, actionlint, zizmor, markdownlint, hadolint, shellcheck, jsx-a11y, pa11y, …), applies safe autofixers, and writes `.code-analysis/summary.json` + `report.md` (git-ignored — never appears in the diff). Stage whatever the autofixers changed.

**2. Then run the project linter --fix if one was detected** (Step 3) — it catches formatting (Prettier), type-checking (tsc), and custom lint rules the analyzer set doesn't replicate. Stage those changes too.

**3. Read `.code-analysis/summary.json` and fold the *remaining* (non-autofixed) findings into the cycle:**

- **Security / secrets / SAST** — findings from `gitleaks`, `semgrep`, `brakeman`, `govulncheck`, `zizmor`: treat each as a high-confidence (≥80) finding. **Do not Haiku-score them** — the tool already verified them. Attempt a fix and route through Step 7 / Step 8a exactly like a review-agent finding (the risk profile still decides auto-apply vs. ask). These are the ones that matter.
- **Quality / style residue** — anything the autofixers couldn't fix: don't run it through the agents or Haiku (deterministic, mostly low-value). Carry the per-tool counts into the final report (Step 14).
- **Skipped tools** — if the run skipped analyzers (not installed, no ephemeral runner) and you can prompt the user (main interactive agent, not a headless subagent), offer once to install them (use each entry's `install_hint`) and re-run. In a subagent run, just note the skips in the report; never block.

## Step 4b: Establish PR Intent (for Agent #9) and capture the spec artifact (for Agent #11)

Agent #9 (intent reconciliation, Step 5) reviews the change against what it is *supposed* to do, so it needs an accurate statement of intent — and it must be **intent, not a description of the code**. Establish this once, before the loop.

1. **Gather intent sources** (most trusted first): the linked issue / acceptance criteria, the PR description, the branch's commit messages, the title. With no PR yet (local branch), the commit messages + issue are the intent.
2. **Gate — decide whether Agent #9 runs at all.** Skip it (and the rest of this step) when the change has no reviewable intent to model against: dependency bumps, pure refactors/renames, formatting, config-only changes, or any diff whose purpose can't be stated as intended *behavior*. It earns its cost only on feature / behavior-changing work with a derivable goal.
3. **Build the intent statement — do NOT edit the PR description here.** Distil the sources into an internal statement of the change's purpose and intended behavior for Agent #9. Keep it to GOALS ("users can reconnect a third-party account"), never claims about what the code does or that an edge case is handled — an intent derived by reading the implementation just mirrors the code and blinds Agent #9 to the omissions it exists to catch. If the sources are too thin to state a goal: derive one from the issue/commits, or (interactive runs only) ask the author; if none can be established, gate Agent #9 off (step 2). The description itself is made accurate and complete *later* — **Step 14 reconciles it against the final reviewed change**, when doing so is safe (the code is final, so describing it can't launder a bug into intent) and useful (the PR ends merge-ready).
4. The resulting intent statement is what Agent #9's stage 1 consumes. Treat it as *desired behavior to be verified against the code*, not as ground truth about what the code does.
5. **Capture the written spec artifact, if one exists — this is separate from the intent statement.** Intent is *distilled goals*; the artifact is *the text someone wrote down and is accountable to*: an agent brief comment on the issue, a linked issue body with acceptance criteria, or a spec file under `docs/`/`specs/`/`.scratch/`. Fetch it **verbatim** (`gh issue view <n> --comments`) and keep it as-is — Agent #11 quotes its lines, so paraphrase destroys the point. If several exist, prefer the most specific and most recent: an agent brief beats the issue body it was posted on. If none exists, record that and gate #11 off. If the fetch fails or returns an error instead of the text (e.g. a sandbox `Forbidden`), treat it the same way — gate #11 off and say so; never hand #11 an error message as its spec. This is a fetch, not a judgement call — do not synthesise an artifact from the code or the commits; a spec derived from the diff can only ever agree with it.
6. **While intent is in hand, draft the measurement hypothesis** for Step 13.5 — one line: the user-visible effect this change is supposed to produce, stated directionally ("fewer users drop at the mapping step"). It costs nothing here and it's the honest version: written from the goal, before you've seen which numbers happen to be available. Carry it to Step 13.5, which turns it into a plan and verifies the instrumentation. Skip if that step's gate obviously won't fire (no user-facing behavior changes).

## Step 5: Parallel Review Agents

Spawn the review subagents in parallel (single message, multiple Agent tool calls). Agents #1–#4 and #6 always run; the **security review** (which replaces the old Agent #5) runs alongside them on every cycle — see below. Agents #7 (structural simplification) and #8 (observability & cost coverage) run **only on substantial diffs**; Agent #9 (intent reconciliation) runs **only in cycle 1 and only when Step 4b established a reviewable intent**; Agent #10 (prior review feedback) runs **only in cycle 1 and only when `gh` can reach the repo**; Agent #11 (spec conformance) runs **only in cycle 1 and only when Step 4b captured a written spec artifact** — see each agent's gating rule.

**This cycle's review scope** (Step 4 loop, step b): `git diff origin/<base_branch>...HEAD` on cycle 1, or `git diff <prev-cycle-sha>...HEAD` on cycles 2+. Below, "the diff" means this scope; "the whole changed files" means those files' full contents at HEAD.

**Two agent classes — they get different context:**

- **File-scoped** — **#1 standards, #2 bugs, #4 comments**. These reason *within* a file, so give them the **whole changed files**, not just the diff. Omission bugs — state that should reset/invalidate but doesn't, a contract left unenforced, an error path that logs instead of throwing, a flag set before the action it gates — are invisible in a diff-of-additions and only surface against the full file. (Measured on this skill's eval: whole-file flipped a modified-file omission miss from 1/3 → 3/3; diff-only stayed blind. See `evals/`.)
- **Diff-scoped** — **#3 history, #6 tests, #7 structural, #8 observability & cost, #10 prior review feedback**. These reason *across* files and relationships, so give them the whole cycle diff (they may still read *beyond* it per their rules — the scope only bounds what counts as "under review"). One agent each.

**Batching the file-scoped agents (context budget).** Don't hand one agent every changed file (attention dilutes — measured: whole-PR context tanked recall to 0) nor spawn one agent per file (needless fan-out and cost). Instead run:

```
python3 ~/.claude/skills/review-loop/batch-files.py <this-cycle's diff-range>
```

It bin-packs the changed files into **batches under a ~1500-line whole-file budget** and lists any oversized file to handle by diff-plus-enclosing-scope. **Spawn one instance of each file-scoped agent per batch, in parallel**, each receiving the whole contents of its batch's files plus the diff of what changed in them. On a normal PR this is a single batch = one instance each (identical to before); it only fans out when the changed files exceed the budget — which is exactly where attention-splitting starts to hurt. Batches are disjoint file sets, so instances of the same agent never produce duplicate findings.

**Shared agent inputs go in one fixed place:** `<git-common-dir>/info/review-loop-run/` (clear it at the start of each run). Write the diff, the spec artifact, and any shared brief there and pass agents the path. Not `$TMPDIR`: it resolves to a different directory with the sandbox on vs. off, so a file written by an unsandboxed fetch can silently miss the copy the agents read.

Each agent must also receive:

- The contents of `.git/info/review-loop-learnings.md` if it exists, with instructions: "If a finding matches anything in the Dismissed list, do not flag it."
- The agent's specific focus (below)
- The style default below (verbatim)
- A required output shape: a JSON-like list of `{file, line_range, description, suggested_fix, reasoning}`

**Model tier (pass to the Agent tool's `model` param):** pin **every** review agent to `sonnet`. Rationale and the decision record: `references/model-choice.md` (short version — Sonnet 5 lands near Opus 4.8 on review-defect-finding, so the top tier no longer buys enough to justify its cost, and a single review fan-out was burning a whole Opus session).

- **All review agents — pin to `sonnet`**: **#1 standards**, **#2 bugs**, **#3 git history**, **#4 comments**, **#6 test coverage**, **#7 structural**, **#8 observability & cost**, **#9 intent-recon**, **#10 prior review feedback**, and both stages of the **security review**.

**Read `references/agent-roster.md` before spawning.** It carries the style-default paragraph every agent receives verbatim, plus the focus brief for each of #1–#6:

| # | Agent | Scope |
| --- | --- | --- |
| 1 | Standards compliance (CLAUDE.md + smell baseline) | file-scoped, whole-file, batched |
| 2 | Bug scan — commission *and* omission | file-scoped, whole-file, batched |
| 3 | Git history | changed regions, via `git log -p -L` / `git blame` |
| 4 | Code comments compliance | file-scoped, whole-file, batched |
| — | **Security review** (replaces #5) | diff + threat model — **`references/security-review.md`** |
| 6 | Test coverage | diff |

### Security review (replaces Agent #5) — **Read `references/security-review.md`**

Not one of the numbered roster agents any more. It is Anthropic's `/security-review` prompt, vendored, whose exclusion list and precedents were tuned on production false positives across many repos — plus two additive departures: the **threat model is injected** rather than re-derived each run, and findings **route into the loop** instead of terminating in a markdown report.

Two stages, and the fan-out is on *verification*, not discovery:

1. **Finder** — one `sonnet` agent. Gets the cycle diff, the changed files, the threat model, and the learnings file.
2. **False-positive filter** — **one `sonnet` subagent per finding, in parallel**, each returning a confidence 1-10. Usually 0-3 of these; on a clean diff, zero.

**Runs every cycle** except the fast path. **On cycles 2+, run it only if a security fix was applied last cycle**, scoped to the applied hunks — authorization fixes are always-ask, so the user is their sole reviewer, and nothing else re-reads them.

**Do not "improve" the exclusion list from first principles.** Amend it only through the threat model's per-repo override (`## Not an issue here` / `## Watch this spot`), which is evidence-backed by construction.

### Agents #7, #8, #9, #10, #11 — conditional (focus detail in `references/conditional-agents.md`)

Evaluate each gate every run; the gate is here, the focus/scoring/routing is in the reference. When a gate fires, **Read `references/conditional-agents.md`** for that agent's full instructions before spawning it.

- **#7 Structural simplification** `[sonnet]` — spawn on **substantial diffs**; skip when ALL hold: diff < ~150 changed lines, no file past ~800 lines, and pure bugfix/config/dependency bump. Reads beyond the diff. Scored on value-vs-risk, **never auto-applied** (asked at ≥40, report-only below).
- **#8 Observability & cost coverage** `[sonnet]` — spawn when the diff is substantial/risky (#7's threshold) **AND** either the repo has an observability convention (logger/metrics/error reporter) **or** the diff touches a metered resource (paid API, LLM call, CI workflow, cron schedule, queue, cache, storage). Skip the observability half if the project logs nothing. Normal Step 6 rubric; fixes usually additive/auto-applied.
- **#9 Intent reconciliation** `[sonnet]` — spawn **only in cycle 1** when Step 4b established a reviewable intent. Two stages in separate contexts (spec from intent only → reconcile against code). **Never auto-applied** (asked at ≥40, report-only below); highest false-positive rate — lean on the Dismissed list.
- **#11 Spec conformance** `[sonnet]` — spawn **only in cycle 1**, and only when Step 4b captured a **written spec artifact**. Checks the diff against that text on three axes: requirements missing/partial, behaviour present that the spec never asked for (scope creep), and requirements implemented but implemented wrong. Every finding quotes the spec line. **Bypasses Step 6 scoring entirely and is always ask-routed**; reported in its own section so a spec miss can never be outranked by a style nit. Distinct from #9 — #9 *derives* expected behaviour and hunts omissions; #11 *checks against text someone wrote*.
- **#10 Prior review feedback** `[sonnet]` — spawn **only in cycle 1**, and only when `gh` is authenticated and the repo has a GitHub remote. Mines review comments on past merged PRs that touched the same files and checks whether any apply again here. Skip on a repo with no PR history for the changed files. Normal Step 6 rubric; findings carry a citation to the prior comment.

## Step 6: Haiku Scoring

**Gate: if Agent #9 fired, its Stage 2 (reconcile) must have returned before scoring starts.** Stage 2 depends on Stage 1's output, so it can never be in the same parallel batch — a batch that includes #9 has only launched Stage 1.

**Security findings and Agent #11 spec-conformance findings do not come here.** Spec findings carry their own severity in their three-way classification and are always ask-routed; scoring them would re-merge the axis this separation exists to keep apart.

**Security findings:** The security review's Stage-2 filter *is* their scorer (confidence 1-10 → score ×10); do not also run a Haiku scorer over them. Their floor is higher than the loop's general band — see `references/security-review.md`.

**Score per review agent, not per finding.** Spawn **one Haiku scorer subagent per review agent that returned findings** (so the scorers run in parallel, one alongside each finder). Each scorer receives that agent's *entire* finding-list and scores every finding in a single pass. Do NOT spawn one scorer per finding — that re-ships the diff once per finding and is the loop's biggest token sink. If a single agent returned an unusually large batch (>~12 findings), split it across two scorer calls to keep each pass careful, but never go back to one-per-finding.

The scorers stay independent from the finders (a fresh context that didn't generate the findings), so the quality intent — an independent rater — is preserved; you're only collapsing redundant diff copies.

Give each scorer:

- **Only the diff hunks the findings reference** — not the whole diff. Use the slicer to extract exactly those hunks deterministically:

  ```bash
  python3 ~/.claude/skills/review-loop/slice-hunks.py <diff-range> <file:start-end> [<file:start-end> ...]
  ```

  where `<diff-range>` is this cycle's review scope (`origin/<base_branch>...HEAD` on cycle 1, `<prev-cycle-sha>...HEAD` on cycles 2+) and each remaining arg is a finding's `file` plus its `line_range`. It prints only the hunks overlapping those ranges, grouped by file — no eyeballing, same slice every time. (For findings that cite code *beyond* the diff, the slicer won't capture it — read that region from the file and add it manually. This is expected for the file-scoped agents #1/#2/#4, whose whole-file review can flag an omission at an unchanged line, and for #3/#7/#8 by their nature.)
- The relevant `CLAUDE.md` paths
- The finding-list (each `{file, line_range, description, reasoning}`)
- The learnings file contents
- This rubric (verbatim), instructing it to **return one integer per finding, keyed by finding**, scoring each independently of the others in the batch:

**Read `references/scoring-and-routing.md`** for the rubric to pass verbatim (the 0-100 anchors, the Dismissed/Accepted adjustments) and for the two agents that score on a different basis — #7 structural on value-vs-risk, #9 intent on plausibility × impact-if-true. Neither is ever auto-applied; they are asked at ≥40 and report-only below.

## Step 7: Apply Auto-Fixes (≥80)

For each ≥80 finding, in dependency order (same file → process top-to-bottom by line number to keep line refs valid):

1. Read the file
2. Apply the `suggested_fix` via Edit
3. If the suggested_fix is unclear or conflicts with current state, drop the finding to the 50-79 bucket so the user is asked

## Step 8a: Risk profile — decide which 50-79 findings need a human

A 50-79 confidence score means *you* aren't sure, not necessarily that the *user's* input is required. Cheap-to-undo, low-blast-radius fixes don't deserve an interruption — just apply them and let the user override later if they object.

Before asking, classify each 50-79 finding on three dimensions. A finding goes to **auto-fix** when ALL of the following are low-risk; otherwise it goes to **ask-user**.

The three dimensions — **reversibility**, **blast radius**, **forward-binding** — and the three hard rules that override the matrix are in **`references/scoring-and-routing.md`**. Read it before classifying.
**Bucket deterministically once each finding is classified.** After scoring (Step 6) and the risk classification above, assemble one JSON object per finding — `{id, agent, score, risk: "low"|"high", always_ask: bool, cost_recurrence, category, behavioral, observed_failure}`, with `agent` set to the exact ids the script matches (`7-structural`, `9-intent`, `5-security`, `5-security-authz`; anything else routes as an ordinary finding) — and route them with:

```bash
echo '<findings-json>' | python3 ~/.claude/skills/review-loop/bucket.py
```

**Four fields beyond the score, each closing a measured miscalibration:**

- **`cost_recurrence`: `"once"` | `"per-use"` | `"per-item"`.** Is the consequence paid once, or every time the system is used / per item it handles? Answer it about the *consequence*, never about the size of the fix. A recurring cost is never skipped on a low score — it floors to ask, because you are reading a diff and the diff cannot show you how often the operation runs. This exists because a cache-key change that re-rendered every prior artifact on each new opt-in was filed as a wording nit: one line, one file, soften the prose. The real cost was ~70 minutes of CI per rollout. An unrecognised value is **refused**, not defaulted — a typo must not buy the cheaper routing.
- **`category`.** Set `"comment-accuracy"` for "this comment claims more than the code does". Counted apart from defects in the record and the report, because it is legitimate work but not defect-finding, and merging them makes a run look more productive than it was. **`"comment-accuracy"` together with a recurring `cost_recurrence` is refused as a contradiction** — a cost paid on every use is not a wording problem, and that pairing is precisely the mistake above. Decide which it is.
- **`behavioral`: bool** — does the finding claim the program behaves wrongly, as opposed to being unclear, duplicated or badly named?
- **`observed_failure`: string** — for a `behavioral` finding, *the failure you watched happen before the fix existed*. A behavioral claim without one never auto-applies. One run "fixed" CRLF handling with a regex that already worked, and its verification, run only afterwards, passed exactly as it would have without the fix. **Construct the failing case and watch it fail first; a check that never saw the failure cannot tell a fix from a no-op.**

A contradiction refuses the whole batch, not just the offending finding — the one you described incorrectly is the one most worth looking at again.

It emits `{auto_fix, ask, skip}` applying the exact thresholds (≥80 → auto; 50-79 low-risk → auto, else ask; Agent #7/#9 and `always_ask` → ask at ≥40, report-only below; <50 → skip) so the routing can't drift between runs. The judgment stays yours — the *score* (Step 6) and the *risk* and *always_ask* flags (this step) — the script only combines them.

When auto-applying a 50-79 finding without asking, note it in the cycle commit message (Step 10's subject, then `(auto-applied low-risk: <one-line summary of each>)`) so the user sees what landed without their say-so.

If after Step 8a the ask-user bucket is empty, skip Step 8b entirely.

## Step 8b: Batched approval for the remaining (high-risk) 50-79 findings

After auto-fixes are applied, present the remaining 50-79 findings as one AskUserQuestion (or sequential if there are more than 4 — AskUserQuestion caps at 4 options per call, so use multiple calls if needed). For each:

- Option "Apply fix" — apply the suggested fix
- Option "Skip" — record as a dismissal in learnings
- Option "Skip and remember as a dismissal pattern" — record with broader pattern wording

Apply approved fixes the same way as Step 7.

The framing matters as much as the routing — the user is making a judgment call you couldn't make, on code they may know shallowly. **Read `references/scoring-and-routing.md`** ("Framing the question") before writing the `question` field.

## Step 9: Test Run

Run the detected test command. Stream output. If exit code is non-zero:

1. Stop the loop immediately
2. Report the failing tests with their output
3. Tell the user: "Tests failed after this cycle's fixes. Last commit is `<sha>`. Investigate, fix, and re-invoke."
4. Do not auto-revert — let the user decide whether to revert or fix forward

## Step 10: Commit the Cycle

Stage all files changed this cycle (lint --fix changes + auto-fixes + user-approved fixes) and commit with a conventional commit message summarizing the cycle:

```bash
git add <changed-files>
git commit -m "fix(review): cycle <N> — <short summary of categories addressed>"
```

`review` is the default scope only. If the repo restricts scopes (commitlint `scope-enum`, a CONTRIBUTING rule), use an allowed one instead, e.g. `fix(api): review cycle <N> — …`.

Summary should mention the agent categories whose findings drove the cycle (e.g. "security + bug scan + CLAUDE.md").

After committing, record this commit's sha (`git rev-parse HEAD`) as the previous-cycle marker so the next cycle's review scope (Step 4 loop, step b) diffs against it. If the cycle made no commit (nothing to fix), the marker stays where it was.

**Then record the cycle in the run record — every cycle, including the one that applied nothing:**

```bash
python3 ~/.claude/skills/review-loop/runlog.py cycle --run-id <run_id> --n <N> \
  --applied <fixes applied> --asked <ask-bucket items> \
  --defect-findings <n> --comment-findings <n> \
  --agents <agents spawned this cycle> [--tokens <observed subagent tokens>] \
  [--analysis-changed]
```

This is the only thing that answers "was the review finished, or did we stop?" — Step 14's push
checker derives convergence from these rows rather than being told, and **a run with no cycle rows
reads as *did not converge*.** The zero-fix cycle is the most important one to record, because it is
the row that proves the loop ran out of findings rather than out of budget.

Two counts, not one: a finding that a comment claims more than the code does is legitimate work but
it is not defect-finding, and counting them together makes a run look more productive than it was.
`--agents` is the cap's unit; `--tokens` is recorded but never enforced, so the proxy can be checked
against real spend later.

## Step 11: Capture Learnings

On Step 8b outcomes, record learnings in `.git/info/review-loop-learnings.md` (two sections: **Dismissed**, **Accepted patterns**). It's re-shipped to every agent, so keep it a curated index, not a log.

**Also record every Agent #10 finding that survived** — including ones auto-fixed at Step 7, which never reach Step 8b. #10 is the only agent whose findings come from outside the repo (`gh` review history), and it runs at most once per branch, so an unrecorded #10 finding costs the same API calls to rediscover next time. Write it to **Accepted patterns** with its citation intact ("PR #1042, @jakecoble: don't call this from the request path"). This is how a repo's most-repeated human review feedback migrates from GitHub into the local learnings file, where Agents #1–#4 and #6 see it for free on every subsequent run.

**Security dismissals go to the threat model, not here.** When the user skips a *security* finding at Step 8b, write it under `## Not an issue here` in `<git-common-dir>/info/review-loop-threat-model.md` with today's date and a `[path @ sha]` pin. That file is the per-repo override channel for the vendored exclusion list, and it is the only section the security review reads for suppressions. A security dismissal in the learnings file is invisible to it.

Do the edits with `learn.py` — you judge match/novelty/section; the script does the dated surgery:

- Re-match of an existing entry → `python3 ~/.claude/skills/review-loop/learn.py bump <file> "<substring>"` (bumps its date to today — the freshness signal Step 2a depends on).
- Novel entry → `learn.py add <file> --section dismissed|accepted "<text, no date>"` (stamps today's date; creates the file/sections if missing).
- Cap fallback → `learn.py prune <file>` (evicts oldest non-PATTERN, dismissed first; PATTERN entries never auto-pruned).

For the entry shape, the dedup/promote judgment, the per-Step-8b-outcome mapping, and the cap/split fallbacks, **Read `references/learnings-format.md`**. When in doubt whether an entry is worth writing, don't — the file's value is being scannable, not exhaustive.

## Step 12: "Remember X" Requests During the Session

If the user says "remember X", "always check Y here", "this repo cares about Z", or similar at any point during the session, immediately append to `.git/info/review-loop-learnings.md` under the appropriate section (Dismissed for "stop flagging…", Accepted for "always flag…"). Acknowledge with one sentence. Do not derail the loop.

If what the user wants remembered is a **security** concern anchored to a location ("keep an eye on this", "this spot is sensitive", "don't let anything widen that"), write it under `## Watch this spot` in the threat model instead, with a `[path:line @ sha]` pin. Those entries *override* the vendored exclusion list: a finding landing on a watched location is reported even when a generic precedent would drop it. This is the channel that keeps a repo-specific risk (e.g. a Sentry depth limit that is load-bearing PII containment) from being filtered away as routine.

If the user explicitly says "remember globally" or "remember for all repos", offer to also write to `~/.claude/projects/-home-narthur/memory/` as a separate auto-memory entry.

## Step 13: Manual-Testing Evidence Gate

Runs **only after everything else passes** — a clean loop exit (auto-fix bucket empty, tests green, no unresolved high-risk findings). It is the last gate before Step 14's report/auto-push.

**Skip entirely** (say so in one line in the final report) when either:

- **No PR exists** for the branch (`gh pr view` fails) — there's nowhere to attach evidence *yet*. This is **deferred, not dropped**: Step 14 records the deferral (`.git/info/review-loop-pending-report.md`) and Step 0c runs this gate once a PR appears. Only genuinely skip when the second condition also holds.
- **The diff changes no runtime functionality** — docs, comments, config, dependency bumps, CI-only changes, or pure refactors already pinned by tests. The gate is about *changed behavior*, and when in doubt, run it.

Otherwise the gate is active — **Read `references/evidence-gate.md`** and follow it: 13a (check the PR for sufficient existing evidence) → 13b (stand up the app and produce evidence yourself if missing — playwright for UI, real requests for API/CLI) → 13c (publish to the PR; or on a found issue, stop, fix, and restart the loop from cycle 1, capped at 2 restarts; or report "can't test" and don't push).

## Step 13.5: Impact Measurement Gate

Runs **immediately after Step 13 passes**, on the same clean-exit precondition. Step 13 proves the change works; this gate proves you'll be able to tell whether it *helped*. It is the last point where that's still fixable, because the fix is code in this PR — instrumentation added after merge has no pre-ship baseline to compare against.

**Skip entirely** (say so in one line in the final report) when any holds:

- **The diff changes no user-facing behavior** — same condition as Step 13, plus internal-only changes whose effect no user could experience. When in doubt, run it.
- **The repo has no measurement capability at all** — no product-analytics events, no metrics client, no telemetry, no queryable usage data. Don't invent a stack to satisfy the gate; that's a project decision, not a review finding. (Mirrors Agent #8's "skip if the project logs nothing".)
- **No PR exists** for the branch — **deferred, not dropped**, exactly as Step 13: Step 14 records it in `.git/info/review-loop-pending-report.md` and Step 0c runs it once a PR appears.

Otherwise the gate is active — **Read `references/measurement-gate.md`** and follow it: 13.5a (turn the Step 4b hypothesis into a five-line plan: effect, metric, baseline, window+threshold, guardrail) → 13.5b (verify in the code that each metric is actually emitted on the changed path, segmentable, flag-symmetric, and baseline-readable now) → 13.5c (publish the plan to the PR, **put it in a commit message so it survives in git**, and **file a Taskwarrior follow-up due at the window's end carrying the exact query**; or on a gap, stop, instrument in this PR, and restart the loop from cycle 1 — sharing Step 13's 2-restart cap; or waive with a stated reason).

**A waiver is a real outcome, not a failure** — some changes genuinely can't be measured. It just has to be said out loud, with its reason, in the report and on the PR. What the gate exists to prevent is the silent version.

## Step 14: Final Report and Auto-Push

Five things, in order. **Read `references/finish.md`** for the rules behind each — the reconcile's
timing, the record-reviewed honesty rule, and the full "when NOT to auto-push" spec.

0. **Close the run record** — every exit, including a cycle-limit or test-failure one:

   ```bash
   python3 ~/.claude/skills/review-loop/runlog.py finish --run-id <from Step 0b> \
     --outcome clean|cycle-limit|test-failure|blocked \
     --tier fast|full|partial \
     --executed '{"<gate>":{"status":"done|skipped|failed|n/a","reason":"..."}}' \
     --escalations '[{"gate":"...","reason":"..."}]' \
     --agents '[{"id":"2-bugs","model":"sonnet","status":"ok","findings":3}]' \
     --findings '{"auto_fix":N,"asked":N,"skipped":N}' --asks <unresolved ask-bucket items>
   ```

   One `executed` entry per gate the plan marked `run` — **`finish` refuses and writes nothing if
   one is missing**, so account for each gate or record an escalation. If a planned gate genuinely
   went unrun, add `--allow-unaccounted`: the run is recorded, the gate is named as unaccounted, and
   the tier becomes `partial`. Use `n/a` — which does *not* force `partial` — when the gate had
   nothing to act on (no PR exists, the repo has no telemetry); use `skipped` when you chose not to
   run one that could have run. Every status but `done` needs a reason. `partial` is the tier when any planned agent
   failed or any planned gate went unexecuted — the label and the push gate both read it that way.
   Non-interactive session with a non-empty ask bucket (`AskUserQuestion` aborts in headless and AO
   worker runs): leave those findings unapplied, list them in the PR as open questions, and pass the
   count to `--asks`; inside AO also `ao report --needs-input`. Never widen auto-apply because nobody
   is there to ask.

1. **Reconcile the PR description, then post the report as a PR comment.** Clean exit with a PR
   only. Skip the reconcile on a cycle-limit or test-failure exit. Clean exit with **no PR yet** →
   both are *deferred* to `.git/info/review-loop-pending-report.md`, and Step 0c flushes them.
   The fast path and fast-path re-entry are included: a one-reviewer run still posts (or defers)
   its summary, labelled as a fast-path cycle.

2. **Record the reviewed commit** — clean exit only, **before** the push decision:

   ```bash
   ~/.claude/skills/review-loop/record-reviewed.sh
   ```

   This is the skill's completion stamp: it asserts the loop actually looked at this tip. Never
   hand-call it to clear the pre-push gate on a change the loop didn't examine — re-run the Step 3b
   fast path, or state the judgment with `record-skipped.sh "<reason>"`, which clears the gate
   while recording a *distinct* state that can't masquerade as a review.

3. **Decide the push with the checker**, never by re-deriving the checklist:

   ```bash
   python3 ~/.claude/skills/review-loop/push-check.py --run-id <run_id> \
     --gate-state <passed|skipped|blocked> [--unresolved-skip] \
     --branch <current> --default-branch <default>
   ```

   **You do not tell it whether the loop converged — it reads that from the record.** There is no
   `--clean-exit` any more: the one question this script exists to answer used to be answered by
   the orchestrator asserting a flag, which is how a run recorded `clean` while its own author
   reported it had not converged. Convergence is derived from the `cycle` rows you recorded at
   Step 10, so **a run with no cycle rows reads as "did not converge"** — recording them is how the
   honest path stays the cheap one.

   **Not converging does not block the push.** A cap that strands commits only hands the decision
   back to the user. A `capped` or `halted` run pushes and the output carries `disclose` — the line
   the PR summary must say, verbatim, about how far the review got. Omitting it turns a disclosed
   push into a silent one, which is worse than the stall it replaced.

   Then publish the disclosure — **from the record, not from memory**:

   ```bash
   printf '%s\n' "<your findings narrative>" \
     | python3 ~/.claude/skills/review-loop/pr-report.py --run-id <run_id> --post --label
   ```

   It renders convergence, the disclosure, every gate with its reason, the cycle table, the sizing
   numbers and the roster from the run record, appends your narrative verbatim, labels the PR
   `review:<convergence>`, and defers to the pending-report file by itself when there is no PR yet.
   **When `disclose` is non-null this step is not optional** — a capped run may push only because it
   says so, and a capped push that says nothing is worse than one that stalls.

   Push only on `push: true` (`git push`, or `git push -u origin <branch>` when `reason` says there is no upstream yet). On
   `false`, surface `reason` and end the report with `Next step: <reason>; push when ready.` If the
   push itself fails, surface the error verbatim and continue — don't retry, don't force.

4. **Emit the report** — the exact block is in `references/report-format.md`.

## Quick Reference

| Operation | Command |
| --- | --- |
| Status | `git status` |
| Stage | `git add <file>` |
| Commit | `git commit -m "..."` |
| Push (user-initiated) | `git push` |

| Bucket | Score | Risk profile (Step 8a) | Action |
| --- | --- | --- | --- |
| Ask user | ≥40 | structural finding from Agent #7 | Surface as proposal; never auto-apply |
| Ask user | ≥40 | baseline smell from Agent #1 (name / duplication) | Heuristic — surface as proposal; never auto-apply |
| Report-only | <40 | any always-ask finding (#7, #9, #1 baseline, `always_ask`) | Listed in the report (#7 nits / #9 questions), not asked; never auto-applied |
| Auto-fix | ≥80 | (any) | Apply silently |
| Auto-fix | 50-79 | all three dimensions low-risk | Apply silently; note in commit message |
| Ask user | 50-79 | any dimension high-risk OR fix unclear OR `always ask` rule applies | Batch via AskUserQuestion |
| Skip | <50 | (any) | Reported in final summary count only |
| Ask user | ≥80 | authorization finding (`5-security-authz`) | Never auto-apply — a wrong authz fix locks out real users |
| Auto-fix / Ask | ≥80 | security, non-authz | Stage-2 filter confidence ×10; normal risk profile |
| Skip | <80 | security (any) | **Listed line-by-line** in the report — no 50-79 band for security |
| Ask user | (unscored) | spec-conformance finding from Agent #11 | Bypasses Step 6; never auto-apply; own report section, each with its spec quote |
