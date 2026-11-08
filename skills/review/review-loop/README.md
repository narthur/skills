# review-loop

A pre-push code review for [Claude Code](https://claude.com/claude-code) that runs a team of review agents over a branch, fixes what it is confident about, asks about the rest, and repeats until a pass finds nothing new.

The agent's instructions are in [`SKILL.md`](SKILL.md). This page is for people.

## What a run does

1. **Static analysis first.** Linters, SAST, secret scanning and the project's own lint/format commands run and auto-fix before any model looks at the code. The review agents leave that territory alone.
2. **Parallel review agents.** Each one has a single lens: project standards (`CLAUDE.md`), bugs (including *omissions*, such as state that should reset and doesn't), git history, comment accuracy, test coverage, and a security review built on Anthropic's `/security-review` prompt. Larger or riskier diffs add agents for structural simplification, observability and cost, intent ("does this do what it was meant to?"), conformance to a written spec, and review comments left on earlier PRs that touched the same files.
3. **Independent scoring.** A separate, cheaper model scores every finding 0–100 for confidence, without having produced it.
4. **Routing.** High-confidence fixes are applied. Mid-confidence fixes are applied too when they pass the risk check below; otherwise they go to a question.
5. **Commit and repeat.** Each cycle is committed on its own, tests run, and the next cycle reviews only what the previous one changed. The loop stops when a cycle finds nothing, or when its agent budget runs out.
6. **Report and push.** A summary is posted to the PR (or held until a PR exists), and a push gate decides whether the branch may be pushed.

## How it assesses risk

Confidence and risk are separate questions. The scorer says how likely a finding is to be real. Whether a human needs to see it depends on what happens if the fix is wrong.

Each finding scoring 50–79 is checked against three questions, taken from [Hills to Die On](https://nathanarthur.com/writing/hills-to-die-on):

- **Reversibility.** Would the fix be hard to undo? A new test or a small edit in one file is easy. Deleting behaviour, changing a public export, touching more than two files, or editing a migration is not.
- **Blast radius.** How much does it affect? A change inside one file, or only to comments or tests, is small. A changed exported signature, or anything imported by three or more files, is large.
- **Forward binding.** Will it shape later decisions? Tightening a guard doesn't. A new abstraction, dependency, naming convention or architectural seam does, because other code will follow it.

If all three answers are low, the fix is applied without asking and noted in the commit message. If any is high, it becomes a question. That is how a large pile of low-confidence findings resolves itself, leaving the human with the few decisions that deserve attention.

Some rules override the three questions:

- Structural refactors, authorization fixes, and findings against a written spec are never applied on score alone.
- A repo's `CLAUDE.md` or learnings can mark a topic "always ask."
- A cost paid on every use, rather than once, is never skipped for a low score: a diff can't show how often a code path runs.
- A finding that claims the code misbehaves needs a failure that was observed *before* the fix existed. Without one, it isn't auto-applied, because a check that never saw the failure can't tell a fix from a no-op.

Even for questions, the orchestrator first forms its own recommendation. When it's clear, the orchestrator acts on it and lists it in the report under "Decided on recommendation," where it can be reversed. It asks only when the choice turns on intent or taste, or when a rule reserves the decision for the human. The details are in [`references/scoring-and-routing.md`](references/scoring-and-routing.md), and [`bucket.py`](bucket.py) applies the thresholds.

## How it maintains a threat model

Anthropic's security-review prompt carries an exclusion list tuned on false positives across many repos. That list is generic. It can't know that a route family has no cookies on purpose, or that a logging depth limit is the only thing keeping cardholder data out of an error tracker. Each repo therefore gets a short threat model, which the security review reads on every run.

- **Bootstrap.** On the first run, one agent answers five questions and stops: how auth works and where it's enforced, where the entry points are registered, where the trust boundaries are, what data would matter if it leaked, and what an attacker could make the system spend or do. Reads and writes are capped (about 30 files read, 60 lines written), since the file is there to prime a reviewer, not to document the system. A repo with nothing an attacker can reach gets one line saying so.
- **Observed vs. inferred.** Every claim is either OBSERVED, verified by reading the code and pinned as `[path:line @ sha]`, or INFERRED, an unverified belief that reviewers treat as a hypothesis to check. The person running the loop may not be a security expert and can't audit the file, so a wrong inference must cost a redundant check, never a missed vulnerability. When in doubt, a claim is INFERRED.
- **Staleness.** Before each review, `looper threat-model` lists every pin whose file has changed since the pinned commit, and every pin whose commit no longer exists. An update agent re-reads each one, then re-pins it, rewrites it or deletes it. It also adds claims for new surface in the diff (routes, jobs, integrations, sensitive fields, metered resources) and demotes anything it couldn't confirm. The file stays under about 120 lines, because a long file dilutes the priming.
- **Per-repo overrides.** Two sections belong to the human. *Not an issue here* records security findings they dismissed, so the same one isn't raised again. *Watch this spot* records locations that must be reported even when a generic exclusion would drop them. Both beat the generic list, in opposite directions, and both carry a date and a pin, so they go stale like everything else.

The file lives outside the repo, in a per-repo store shared by every branch and worktree. Format and agent briefs: [`references/threat-model.md`](references/threat-model.md).

## Design choices worth knowing

- **Gates are computed, not remembered.** A long procedure carried by one model drops exactly the steps that are gates. So a small Go binary, [`looper`](../../../packages/looper/), decides the plan (which agents and gates run, the minimum review tier) from measured inputs, keeps a run record, and makes the final push decision from that record. The orchestrating agent cannot assert its way to "clean."
- **Review depth only goes up.** The plan sets a floor; the agent may escalate above it but never below. "This pattern already exists in the repo" is refused as a reason to review less.
- **Size is measured on what a human would read.** Lockfiles, generated files and whitespace-only changes don't count toward the thresholds, and anything excluded is listed in the report.
- **Whole files for some agents, diffs for others.** Agents that reason within a file get the whole file, because omission bugs are invisible in a diff of additions. This was measured with the replay harness in [`evals/`](evals/).
- **Not converging is disclosed, not hidden.** A run that runs out of budget still pushes, but the PR summary has to say how far the review got. A run with failing tests or a known-broken tree does not push.
- **Per-repo memory.** Each repo gets a learnings file (dismissed findings and accepted patterns, so the same false positive isn't raised twice), the threat model above, and a ledger of deferred findings that resurface when the code they depend on changes.

## Requirements

This skill grew inside one working setup and assumes much of it. To run it as-is you need:

- **Claude Code**, with subagents.
- **`looper`**, built from this repo: `cd packages/looper && GOBIN=~/.local/bin go install ./cmd/looper`. Step 0 refuses a binary built from a different commit than the checked-out skill.
- **The skill at `~/.claude/skills/review-loop`**, since `SKILL.md` calls its helper scripts by that path. `scripts/link-skills` at the repo root sets up the symlink.
- **The [`code-analysis`](../code-analysis/) skill** for the static-analysis pass.
- **`gh`, authenticated**, for PR reports, labels, and the prior-review-feedback agent.
- **A local copy of the `/security-review` prompt**, extracted from your own Claude Code install. Its licence doesn't allow shipping it here; [`references/security-review.md`](references/security-review.md) explains the one setup step.
- **A global pre-push hook** that refuses unreviewed tips. That hook (`review-gate.sh`) lives in a separate dotfiles repo and is not included. Without it the review still runs; nothing *forces* it before a push.

Python 3 and Bash cover the remaining helper scripts.

## Taking ideas instead of the whole thing

The full skill is heavy. Pieces that carry over well on their own:

- one narrow lens per review agent, plus an independent scorer that didn't write the findings;
- routing by score *and* reversibility, so cheap fixes don't interrupt anyone;
- reviewing only the previous cycle's fixes after the first pass;
- a dismissals file fed back to every agent;
- a deterministic tool, not the model, deciding whether the push goes ahead.

## Layout

| Path | What's there |
|---|---|
| `SKILL.md` | The procedure the agent follows |
| `references/` | Detail loaded on demand: agent briefs, scoring rubric, threat-model format, report format |
| `*.sh`, `*.py` | Helpers: file batching, hunk slicing, finding routing, review stamps, git hooks |
| `*.test.sh`, `mutations/` | Tests for the helpers, and planted defects those tests must catch |
| `evals/` | Replays real past review findings to measure agent recall |

## Licence

MIT, like the rest of [narthur/skills](../../../), apart from the `/security-review` prompt, which is not included.
