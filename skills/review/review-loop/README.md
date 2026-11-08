# review-loop

A pre-push code review for [Claude Code](https://claude.com/claude-code). It runs a team of review agents over a branch, fixes what it is confident about, asks about the rest, and repeats until a pass finds nothing new.

The agent's instructions are in [`SKILL.md`](SKILL.md). This page is for people.

## What a run does

1. **Static analysis first.** Linters, SAST, secret scanning and the project's own lint/format commands run and auto-fix before any model looks at the code. The review agents leave that territory alone.
2. **Parallel review agents.** Each one has a single lens. Six run on every review, and five more join when the change calls for them (see the table below).
3. **Independent scoring.** A separate, cheaper model that didn't produce the findings scores each one 0-100 for confidence.
4. **Routing.** High-confidence fixes are applied. Mid-confidence fixes are applied too when they pass the risk check below; otherwise they become a question.
5. **Commit and repeat.** Each cycle is committed on its own, tests run, and the next cycle reviews only what the previous one changed. The loop stops when a cycle finds nothing, or when its agent budget runs out.
6. **Report and push.** A summary is posted to the PR (or held until a PR exists), and a push gate decides whether the branch may be pushed.

## The review agents

Every review agent runs on Sonnet. Numbers match `SKILL.md`. Number 5 was the old security agent, which the security review replaced.

| # | Agent | What it looks for | When it runs |
|---|---|---|---|
| 1 | Standards | Breaks of the repo's `CLAUDE.md` rules, plus a baseline set of code smells | Every cycle |
| 2 | Bugs | Code that does the wrong thing, and omissions: state that should reset and doesn't, an error path that logs instead of failing, a flag set before the action it guards | Every cycle |
| 3 | Git history | Changes that revert an earlier deliberate fix, or drop a condition a past commit added on purpose, found with `git log -L` and `git blame` on the changed regions | Every cycle |
| 4 | Comments | Changes that break guidance written in comments ("must stay alphabetized", "do not call from the main thread"), and comments that claim more than the code does | Every cycle |
| | Security | Anthropic's `/security-review` prompt, given the repo's threat model. One finder, then one false-positive filter per finding | Cycle 1. Later cycles only if the previous cycle applied a security fix |
| 6 | Tests | Non-trivial logic changes with no test covering them, in repos that have a test suite | Every cycle |
| 7 | Structural | Simplifications that delete a layer, branch or abstraction. Never applied on score alone | Substantial diffs: about 150 lines or more, or a file past about 800 lines, and not a pure bugfix, config change or dependency bump |
| 8 | Observability and cost | Missing logging, metrics or error reporting, and unbounded use of paid or metered resources (LLM calls, CI, cron, queues, storage) | Substantial diffs, when the repo has an observability convention or the diff touches a metered resource |
| 9 | Intent | Gaps between what the change is meant to do and what the code does. Writes the expected behaviour from the stated goal alone, then compares it to the code | Cycle 1, when the change's purpose can be stated as behaviour |
| 10 | Prior feedback | Review comments on past merged PRs that touched the same files, checked for whether they apply again | Cycle 1, when `gh` can reach the repo and those files have PR history |
| 11 | Spec conformance | Requirements from a written spec (issue, agent brief, spec file) that are missing, wrong, or never asked for. Each finding quotes the spec line, skips scoring, and always goes to the human | Cycle 1, when a written spec exists |

Agents 1, 2 and 4 get whole files, batched to about 1,500 lines per agent. The rest get the diff. After cycle 1, every agent sees only the previous cycle's fixes.

Two more kinds of subagent support the reviewers. A Haiku scorer, one per reviewer that returned findings, gives each finding a confidence score. On the first run in a repo, a Sonnet agent writes the threat model, and on later runs another one keeps it current (see below).

A diff under about 30 lines that touches no program logic takes a fast path instead: one combined reviewer covering standards, bugs, comments and security, and one scorer.

## How it assesses risk

Confidence and risk are separate questions. The scorer says how likely a finding is to be real. Whether a human needs to see it depends on what happens if the fix is wrong.

Each finding scoring 50-79 is checked against three questions, taken from [Hills to Die On](https://nathanarthur.com/writing/hills-to-die-on):

- **Reversibility.** Would the fix be hard to undo? A new test or a small edit in one file is easy. Deleting behaviour, changing a public export, touching more than two files, or editing a migration is not.
- **Blast radius.** How much does it affect? A change inside one file, or only to comments or tests, is small. A changed exported signature, or anything imported by three or more files, is large.
- **Forward binding.** Will it shape later decisions? Tightening a guard doesn't. A new abstraction, dependency, naming convention or architectural seam does, because other code will follow it.

If all three answers are low, the fix is applied without asking and noted in the commit message. If any is high, it becomes a question. So a large pile of low-confidence findings resolves itself, leaving the human with the few decisions that deserve attention.

Some rules override the three questions:

- Structural refactors, authorization fixes, and findings against a written spec are never applied on score alone.
- A repo's `CLAUDE.md` or learnings can mark a topic "always ask."
- A cost paid on every use, rather than once, is never skipped for a low score: a diff can't show how often a code path runs.
- A finding that claims the code misbehaves needs a failure that was observed before the fix existed. Without one, it isn't auto-applied, because a check that never saw the failure can't tell a fix from a no-op.

Even for findings that become questions, the orchestrator first forms its own recommendation. When the recommendation is clear, the orchestrator acts on it and lists the decision in the report under "Decided on recommendation," where it can be reversed. The orchestrator asks only when the choice turns on intent or taste, or when a rule reserves the decision for the human. The details are in [`references/scoring-and-routing.md`](references/scoring-and-routing.md), and [`bucket.py`](bucket.py) applies the thresholds.

## How it maintains a threat model

Anthropic's security-review prompt carries an exclusion list tuned on false positives across many repos. That list is generic, so it can't know that a route family has no cookies on purpose, or that a depth limit on logging is the only thing keeping cardholder data out of an error tracker. Each repo therefore gets a short threat model, which the security review reads on every run.

- **Bootstrap.** On the first run, one agent answers five questions, then stops. The questions are how auth works and where it's enforced, where the entry points are registered, where the trust boundaries are, what data would matter if it leaked, and what an attacker could make the system spend or do. Reads and writes are capped (about 30 files read, 60 lines written) because the file exists to prime a reviewer. A repo with nothing an attacker can reach gets one line saying so.
- **Observed vs. inferred.** Every claim is either OBSERVED or INFERRED. OBSERVED claims are verified by reading the code and pinned as `[path:line @ sha]`. INFERRED claims are unverified beliefs that reviewers treat as hypotheses to check. The person running the loop may not be a security expert and can't audit the file. So a wrong inference must cost a redundant check, never a missed vulnerability. When in doubt, a claim is INFERRED.
- **Staleness.** Before each review, `looper threat-model` lists every pin whose file has changed since the pinned commit, and every pin whose commit no longer exists. An update agent re-reads each one, then re-pins it, rewrites it or deletes it. The update agent also adds claims for new surface in the diff (routes, jobs, integrations, sensitive fields, metered resources) and demotes anything it couldn't confirm. The file stays under about 120 lines, because a long file dilutes the priming.
- **Per-repo overrides.** Two sections belong to the human. *Not an issue here* records security findings the human dismissed, so the same one isn't raised again. *Watch this spot* records locations that must be reported even when a generic exclusion would drop them. Both beat the generic list, in opposite directions, and both carry a date and a pin, so they go stale like everything else.

The file lives outside the repo, in a per-repo store shared by every branch and worktree. Format and agent briefs are in [`references/threat-model.md`](references/threat-model.md).

## Design choices

- **A tool computes the gates.** A long procedure carried by one model drops exactly the steps that are gates. So a small Go binary, [`looper`](../../../packages/looper/), decides the plan (which agents and gates run, the minimum review tier) from measured inputs. It also keeps a run record and makes the final push decision from that record. The orchestrating agent cannot assert its way to "clean."
- **Review depth only goes up.** The plan sets a floor; the agent may escalate above it but never below. "This pattern already exists in the repo" is refused as a reason to review less.
- **Size is measured on what a human would read.** Lockfiles, generated files and whitespace-only changes don't count toward the thresholds, and anything excluded is listed in the report.
- **Whole files for some agents, diffs for others.** Agents that reason within a file get the whole file, because omission bugs are invisible in a diff of additions. The replay harness in [`evals/`](evals/) measured this.
- **Failure to converge is disclosed.** A run that exhausts its budget still pushes, but the PR summary has to say how far the review got. A run with failing tests or a known-broken tree does not push.
- **Per-repo memory.** Each repo gets a learnings file, the threat model above, and a ledger of deferred findings. The learnings file holds dismissed findings and accepted patterns, so the same false positive isn't raised twice. Deferred findings resurface when the code they depend on changes.

## Requirements

This skill grew inside one working setup and assumes much of it. To run it as-is you need:

- **Claude Code**, with subagents.
- **`looper`**, built from this repo: `cd packages/looper && GOBIN=~/.local/bin go install ./cmd/looper`. Step 0 refuses a binary built from a different commit than the checked-out skill.
- **The skill at `~/.claude/skills/review-loop`**, since `SKILL.md` calls its helper scripts by that path. `scripts/link-skills` at the repo root sets up the symlink.
- **The [`code-analysis`](../code-analysis/) skill** for the static-analysis pass.
- **`gh`, authenticated**, for PR reports, labels, and the prior-review-feedback agent.
- **A local copy of the `/security-review` prompt**, extracted from your own Claude Code install. Its licence doesn't allow shipping it here. [`references/security-review.md`](references/security-review.md) explains the one setup step.
- **A global pre-push hook** that refuses unreviewed tips. That hook (`review-gate.sh`) lives in a separate dotfiles repo and is not included. Without it the review still runs; nothing forces it before a push.

Python 3 and Bash cover the remaining helper scripts.

## Reusable pieces

The full skill is heavy. These pieces carry over well on their own:

- one narrow lens per review agent, plus an independent scorer that didn't write the findings;
- routing by both score and reversibility, so cheap fixes don't interrupt anyone;
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
