---
name: code-analysis
description: Run every applicable automated analyzer against a repo — static tools that read the source (linters, SAST, secrets) plus dynamic ones that drive the running app (pa11y accessibility audits) — detecting languages/configs, running the curated CodeRabbit-weighted set (installed or ephemerally via npx/uvx), and writing results to .code-analysis/. Use when asked to run code analysis, lint the whole repo, run all linters/analyzers, do a code-quality/security/accessibility scan, or check a repo before pushing. Report-only by default; --fix opts into safe autofixers. Subagent-safe (never blocks).
---

# code-analysis

One runner that detects what a repo is written in, picks the right analyzers
(one per concern — no overlap), runs them, and writes machine- + human-readable
results. All detection/dispatch/execution lives in the script; your job is thin.

## Run it

```bash
python3 ~/.claude/skills/code-analysis/code-analysis.py [PATH] [flags]
```

- `PATH` — repo/dir to analyze (default: current directory).
- `--diff` — only files changed vs the base branch (pre-push scope).
- `--staged` — only staged files.
- `--fix` — run safe autofixers (eslint --fix, ruff --fix, rubocop -a, …) first, then report residue.
- `--sql` — include SQLFluff (otherwise on-demand: only runs if the repo has a sqlfluff config).
- `--exit-zero` — always exit 0 (for callers that don't want the gate).

**Exit codes:** `0` clean or only skips · `1` findings present · `2` script error.

## Output (git-ignored, latest overwrites)

```
.code-analysis/
  summary.json   # machine-readable: tools run/skipped, finding counts, exit codes
  report.md      # human-readable, rendered by the script
  raw/<tool>.txt # each tool's raw output
```

## What you do after it runs (thin relay)

1. Relay the one-line result: per-tool finding counts, what was skipped, exit status. Point to `.code-analysis/report.md` for detail.
2. **Do not** re-read every finding and re-analyze — the tools already did that. (Deep triage is review-loop's job, not this skill's.)
3. **Install offer — only if you can actually prompt the user** (you are the main interactive agent, not a headless subagent): if `summary.json` lists skipped-but-installable tools, offer to install them (use each entry's `install_hint`) and re-run. In a subagent, skip this step — just report the skips upward and return `summary.json`.

## Adding a tool

Edit `registry.toml` — one table per tool (fields documented at the top of that
file). Add a count parser in `code-analysis.py` (`COUNTERS`) only if the tool
emits clean JSON; otherwise it falls back to exit-code + line count automatically.

## Scope

Registry covers the languages actually in use here (TS/JS, Ruby/Rails, Python,
Go, CSS/SCSS, Markdown, HTML, YAML/GitHub Actions, SQL, Shell, Docker) plus
all-files secret (gitleaks) and SAST (semgrep) scanning, plus dependency
hygiene (**depend**: e18e module-replacements data via eslint-plugin-depend,
linting `package.json` for deps with native/lighter/maintained replacements),
plus accessibility (**a11y**: eslint-plugin-jsx-a11y over changed `.jsx`/`.tsx`,
catching mechanical defects only — missing alt, unlabeled control,
click-without-key-handler, invalid role; report-only, no autofix). Overlapping tools are
pruned to one per concern; the JS/TS linter is chosen by the repo's own config
(biome.json → Biome, eslint config → ESLint, else oxlint).

**pa11y** is the one *dynamic* analyzer — it drives a real browser against the
running app, so it sees what the static a11y linter structurally cannot: composited
contrast, computed focus order, landmark structure in the rendered DOM. It is gated
on `.pa11yci.json`, the same file `narthur/pa11y-ratchet` reads in CI, so a repo that
already ratchets post-push gets the identical check pre-push for free. `pa11y/run`
skips (exit 0, no findings) when the config declares no `urls` — `blog/.pa11yci.json`
is defaults-only, because the Action feeds it URLs from `sitemap-url` — when any URL
is **not loopback**, or when nothing is listening. It never starts a server; that is
the `run` skill's job.

The loopback rule is a security boundary, not a convenience: `.pa11yci.json` belongs
to the repo *under review*, and `pa11y-ci` re-reads it and visits the whole `urls`
list. Probing only the first URL would let a hostile repo pair a live
`localhost` entry with off-box ones and aim this headless Chrome at cloud metadata or
an internal service, landing the response in `.code-analysis/report.md` — which the
review agents then read. Auditing a deployed URL is `pa11y-ratchet`'s job in CI. Headless Chrome per URL is not free, so it should sit out
review-loop's fast path.

**fallow** (TS/JS dead code, import cycles, duplication, complexity) is
whole-repo only, so it runs only in repos that opted in with a `.fallowrc.json`
/ `fallow.toml` (`npx fallow init`). Its `fix` command deletes "unused" code, so
it is deliberately not wired to `--fix`; run `npx fallow fix` by hand. For
change-scoped output use `npx fallow audit --base <ref>` directly.
