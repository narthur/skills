# narthur/skills

Agent skills for [Claude Code](https://claude.com/claude-code), written by Nathan Arthur and split out of a dotfiles repo so they can be read, borrowed and forked.

26 skills in five groups. Everything here is original work. Skills that are merely *used* — vendor packs, other people's published skills — stay in the dotfiles repo they came from.

## Install

```bash
/plugin marketplace add narthur/skills
```

Or clone and take individual directories; each skill is self-contained.

## Skills

### `github/` — Driving pull requests and issues to done.

| Skill | What it does | Requires |
|---|---|---|
| [`actions-usage-report`](skills/github/actions-usage-report/) | Analyze GitHub Actions usage for a GitHub org and identify ways to cut billable minutes | — |
| [`dependabot-alerts`](skills/github/dependabot-alerts/) | Surface open Dependabot security alerts for the current GitHub repo, prioritized by severity and cross-referenced with any open Dependabot PRs | — |
| [`drive-pr`](skills/github/drive-pr/) | Drive a pull request to a mergeable state: base integrated, conflicts resolved, CI green, every review comment resolved | — |
| [`fix-ci`](skills/github/fix-ci/) | Address failing CI checks for the PR associated with the currently-checked-out git branch | `gh-budget` on PATH |
| [`grooming`](skills/github/grooming/) | Groom project issues by reviewing the most stale (least recently touched) issues one at a time | `session-view` on PATH |
| [`issue-blitz`](skills/github/issue-blitz/) | Go through open issues one-by-one, assess each for actionability, and spawn background agents to fix actionable ones in isolated worktrees with PRs | — |
| [`pr-triage`](skills/github/pr-triage/) | Go through open pull requests and take actions to move them toward merge | `session-view` on PATH |
| [`resolve-feedback`](skills/github/resolve-feedback/) | Retrieve, classify, and resolve PR review feedback from humans and bots — inline threads, review summaries, and PR comments — and mark each one resolved or dismissed on GitHub | — |
| [`split-pr`](skills/github/split-pr/) | Safely split changes from the current branch into a separate pull request | — |
| [`walk-pr`](skills/github/walk-pr/) | Walk through a pull request diff hunk-by-hunk, requiring the user to explain each hunk in their own words before advancing | — |

### `review/` — Reviewing code before it ships.

| Skill | What it does | Requires |
|---|---|---|
| [`review-loop`](skills/review/review-loop/) | Pre-push multi-agent code review loop with auto-fix, finding scores, and per-repo learnings | one setup step — see the skill's `references/security-review.md` |
| [`static-analysis`](skills/review/static-analysis/) | Run every applicable static-analysis tool on a repo — detect languages/configs, run the curated CodeRabbit-weighted analyzer set (installed or ephemerally via npx/uvx), and write results to .static-analysis/ | — |

### `meta/` — Skills that build, audit and improve other skills.

| Skill | What it does | Requires |
|---|---|---|
| [`bitter-lesson`](skills/meta/bitter-lesson/) | Audit a set of Claude Code skills for staleness and over-engineering against current model and harness capabilities, then propose deletions, simplifications and fixes | `$OBSIDIAN_VAULT` |
| [`create-skill`](skills/meta/create-skill/) | Scaffold a new Claude Code skill (personal or project-specific) | — |
| [`refine-skill`](skills/meta/refine-skill/) | Review and improve an existing Claude Code skill | — |
| [`update-project-skills`](skills/meta/update-project-skills/) | Review the current conversation for frictions and problems, then update or create project skills to prevent them in the future | — |

### `media/` — Turning things into images, video and hosted URLs.

| Skill | What it does | Requires |
|---|---|---|
| [`ascii-screenshot`](skills/media/ascii-screenshot/) | Turn colored terminal / ASCII output (charts, TUIs, CLI output, asciigraph, lipgloss/bubbletea views) into a PNG image — preserving ANSI colors — for embedding in PRs, issues, docs, or READMEs | — |
| [`surge-image-upload`](skills/media/surge-image-upload/) | Upload local image(s) to a public surge.sh URL — fallback for when `gh --attach` can't be used, or for markdown outside GitHub | `surge` CLI, logged in |
| [`trim-video`](skills/media/trim-video/) | Trim long idle/static periods in a screen recording (or any video) down to a max duration using ffmpeg scene detection | `ffmpeg` |
| [`ui-mockups`](skills/media/ui-mockups/) | Produce low-fi UI wireframes/mockups as HTML/CSS, render them to a PNG, and (optionally) host the image and embed it in a GitHub issue/PR | `playwright-cli` on PATH |

### `dev/` — Everyday development chores.

| Skill | What it does | Requires |
|---|---|---|
| [`cleanup-worktrees`](skills/dev/cleanup-worktrees/) | Clean up stale git worktrees in the current repo — any tool (Claude, Zenflow, Vibe Kanban, PR triage, etc.) — by checking which branches are merged, then prompting the user to delete them | — |
| [`local-llm`](skills/dev/local-llm/) | Leverage local Ollama models (qwen2.5-coder) for the current task | `llm-local` on PATH, a running Ollama |
| [`name-it`](skills/dev/name-it/) | Brainstorm and evaluate names for a product, company, or library against Daniel Reeves' nominology criteria, then check domain availability across many TLDs | — |
| [`organize-files`](skills/dev/organize-files/) | Organize a folder of files by surveying contents, grouping by type, and presenting a numbered list for user decisions | `pandoc`; a vault map at `~/.config/organize-files/vault-structure.md` |
| [`playwright`](skills/dev/playwright/) | Browser automation using playwright-cli | `playwright-cli` on PATH |
| [`prod-uvis`](skills/dev/prod-uvis/) | Find user-visible improvements (UVIs) deployed to production in the current git repo that are not hidden behind a feature flag | — |

## A note on requirements

The `Requires` column is honest rather than aspirational. These skills grew inside one working setup, and a few still call a helper that lives on PATH rather than in the repo. Where a skill needs something it cannot ship, it checks for that thing and says so, rather than failing halfway through.

Helpers stay outside a skill only when they are shared by several skills or genuinely useful to run by hand. Everything else lives in the skill directory.

## Prior art

[**mattpocock/skills**](https://github.com/mattpocock/skills) is the best collection of Claude Code skills going, and it shaped this repo in three concrete ways: the categorised directory layout, shipping as an installable plugin while symlinking the working copy back for the maintainer, and the habit of writing a skill as a thing that can be handed to someone else rather than a private note to the agent. Several of those skills are in daily use here alongside these; they live in a dotfiles repo rather than this one, because this one is for original work.

Worth reading in its own right — `grilling`, `triage` and `to-spec` in particular.

## Licence

MIT — see [LICENSE](LICENSE).

One carve-out: `review-loop` uses Anthropic's `/security-review` prompt, which that licence does not cover and which is **not** included here. The skill extracts it from a local Claude Code install on first use, so the copy matches the binary it runs against. See `skills/review/review-loop/references/security-review.md`.
