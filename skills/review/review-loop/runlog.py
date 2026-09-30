#!/usr/bin/env python3
"""Two-phase run record for review-loop.

Every run writes a `plan` record at Step 0 and a `finish` record at Step 14.
A plan with no finish is a visibly abandoned run — today that state is
indistinguishable from never having invoked the skill, which is how PR #1359
dropped five gated steps without anyone noticing.

Store: ~/.claude/review-loop/runs.jsonl, append-only, one JSON object per line.
Append-only on purpose: concurrent AO worktree sessions write the same file, and
rewriting it is how `<git-common-dir>/info/review-loop-run/` got clobbered twice.
Readers merge phases by run_id.

  runlog.py plan   --head <sha> --tier <floor> --model <m> --inputs <json> --gates <json>
  runlog.py finish --run-id <id> --outcome <o> --executed <json> [--tier <t>] ...
  runlog.py check  [--head <sha>]        exit 1 if this repo has an unfinished run
  runlog.py abandon --run-id <id> --missing <text>
  runlog.py show   --run-id <id>
"""
import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone

STORE = os.path.expanduser(
	os.environ.get("REVIEW_LOOP_RUNS") or "~/.claude/review-loop/runs.jsonl")


def now():
	return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def git(*args, cwd=None):
	try:
		out = subprocess.run(("git",) + args, capture_output=True, text=True, cwd=cwd, timeout=10)
	except (OSError, subprocess.SubprocessError):
		return ""
	return out.stdout.strip() if out.returncode == 0 else ""


def repo_id():
	"""Stable identity for a repo across worktrees: the common dir's path."""
	common = git("rev-parse", "--path-format=absolute", "--git-common-dir")
	if not common:
		return os.getcwd()
	# .../foo/.git -> .../foo ; a bare repo keeps its own path.
	return os.path.dirname(common) if os.path.basename(common) == ".git" else common


def session_kind():
	if os.environ.get("AO_SESSION_ID"):
		return "ao-worker"
	if os.environ.get("CLAUDE_REVIEW_LOOP_SUBAGENT"):
		return "subagent"
	if not sys.stdin.isatty() and not sys.stderr.isatty():
		return "headless"
	return "interactive"


def append(rec):
	os.makedirs(os.path.dirname(STORE), exist_ok=True)
	line = json.dumps(rec, separators=(",", ":"), sort_keys=True) + "\n"
	# O_APPEND + a single write() under PIPE_BUF is atomic across processes, which
	# is what lets concurrent worktree sessions share one file without a lock.
	fd = os.open(STORE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
	try:
		os.write(fd, line.encode())
	finally:
		os.close(fd)


def load():
	"""Merge phase records into one dict per run_id, newest last."""
	runs = {}
	try:
		with open(STORE, encoding="utf-8") as fh:
			for line in fh:
				line = line.strip()
				if not line:
					continue
				try:
					rec = json.loads(line)
				except ValueError:
					continue  # a torn line never invalidates the rest of the store
				rid = rec.get("run_id")
				if not rid:
					continue
				runs.setdefault(rid, {}).update(rec)
	except FileNotFoundError:
		pass
	return runs


def parse_json_arg(raw, what):
	if raw is None:
		return None
	try:
		return json.loads(raw)
	except ValueError as exc:
		sys.exit(f"runlog: --{what} is not valid JSON: {exc}")


# "It has precedent in the repo" is an invalid justification for reduced review,
# not a weak one: bugs pre-exist, copying a pattern propagates them, and the copy
# is the cheapest moment to catch one. Size and no-logic are measurable facts
# about a diff; precedent is an inference from existing code to its correctness.
BANNED_REASON = (
	"precedent", "already exists in the repo", "matches an existing pattern",
	"matches existing pattern", "same pattern as", "pattern copy", "pattern-copy",
	"copied from existing", "consistent with existing code", "follows the existing pattern",
	"established pattern in this repo",
)


def reject_banned(reasons):
	for where, text in reasons:
		low = (text or "").lower()
		for phrase in BANNED_REASON:
			if phrase in low:
				sys.exit(
					f"runlog: refusing to record {where} — its reason cites precedent "
					f"({phrase!r}).\n"
					"Existing code being similar is not evidence it is correct; a copied "
					"pattern carries its bugs, and the copy is the cheapest place to catch "
					"them. State a measurable reason (size, no logic touched, no runtime "
					"change) or run the gate."
				)


def cmd_plan(a):
	rec = {
		"run_id": a.run_id or uuid.uuid4().hex[:12],
		"phase": "plan",
		"planned_at": now(),
		"repo": repo_id(),
		"branch": git("rev-parse", "--abbrev-ref", "HEAD"),
		"head": a.head or git("rev-parse", "HEAD"),
		"base": a.base,
		"orchestrator_model": a.model,
		"session_kind": a.session_kind or session_kind(),
		# Linked worktrees share a git-common-dir, so repo alone would let one
		# session's open run block another's Stop — the same collision that
		# clobbered review-loop-run/ twice.
		"session_id": os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("AO_SESSION_ID"),
		"tier_floor": a.tier,
		"inputs": parse_json_arg(a.inputs, "inputs") or {},
		"gates": parse_json_arg(a.gates, "gates") or {},
		"changed_lines": a.changed_lines,
	}
	append(rec)
	print(rec["run_id"])


def cmd_finish(a):
	executed = parse_json_arg(a.executed, "executed") or {}
	escalations = parse_json_arg(a.escalations, "escalations") or []
	reject_banned(
		[(f"gate {g!r} as {v.get('status')}", v.get("reason"))
		 for g, v in executed.items()
		 if isinstance(v, dict) and v.get("status") in ("skipped", "failed")]
		+ [(f"escalation on {e.get('gate')!r}", e.get("reason"))
		   for e in escalations if isinstance(e, dict)]
	)
	rec = {
		"run_id": a.run_id,
		"phase": "finish",
		"finished_at": now(),
		"outcome": a.outcome,
		"tier_executed": a.tier,
		"executed": executed,
		"escalations": escalations,
		"agents": parse_json_arg(a.agents, "agents") or [],
		"findings": parse_json_arg(a.findings, "findings") or {},
		"unresolved_asks": a.asks,
		"head_at_finish": git("rev-parse", "HEAD"),
	}
	append(rec)
	print(f"runlog: finished {a.run_id} ({a.outcome})")


def cmd_abandon(a):
	append({
		"run_id": a.run_id,
		"phase": "finish",
		"finished_at": now(),
		"outcome": "abandoned",
		"abandoned_missing": a.missing,
		"head_at_finish": git("rev-parse", "HEAD"),
	})
	print(f"runlog: marked {a.run_id} abandoned — {a.missing}")


def unfinished(repo, head=None, session=None):
	"""Planned runs in this repo with no finish record, newest first.

	A `session` narrows to runs this session started. Runs recorded without a
	session id still match — they predate the field or came from a script, and
	dropping them would silently stop guarding them.
	"""
	out = []
	for run in load().values():
		if run.get("repo") != repo or run.get("phase") == "finish":
			continue
		if head and run.get("head") != head:
			continue
		if session and run.get("session_id") and run["session_id"] != session:
			continue
		out.append(run)
	return sorted(out, key=lambda r: r.get("planned_at", ""), reverse=True)


def cmd_check(a):
	repo = repo_id()
	session = a.session or os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("AO_SESSION_ID")
	mine = [r for r in unfinished(repo, a.head, session)
	        if not a.run_id or r["run_id"] == a.run_id]
	if not mine:
		print("runlog: no unfinished run")
		return 0
	run = mine[0]
	pending = [g for g, v in (run.get("gates") or {}).items()
	           if isinstance(v, dict) and v.get("planned") == "run"]
	print(json.dumps({
		"run_id": run["run_id"],
		"head": run.get("head"),
		"tier_floor": run.get("tier_floor"),
		"planned_gates": pending,
	}, indent=1))
	return 1


def cmd_show(a):
	run = load().get(a.run_id)
	if not run:
		sys.exit(f"runlog: no run {a.run_id}")
	print(json.dumps(run, indent=1, sort_keys=True))


def main():
	p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	sub = p.add_subparsers(dest="cmd", required=True)

	sp = sub.add_parser("plan")
	sp.add_argument("--run-id")
	sp.add_argument("--head")
	sp.add_argument("--base")
	sp.add_argument("--tier", required=True, choices=["fast", "full", "skipped"])
	sp.add_argument("--model", required=True, help="the ORCHESTRATOR's model; review agents are pinned separately")
	sp.add_argument("--session-kind", choices=["interactive", "ao-worker", "headless", "subagent"])
	sp.add_argument("--inputs", help='JSON: {"logic":bool,"behavioral_goal":bool,"runtime_behavior_change":bool,"attacker_reachable":bool}')
	sp.add_argument("--gates", help='JSON: {"<gate>":{"planned":"run"|"skip","reason":"..."}}')
	sp.add_argument("--changed-lines", type=int)
	sp.set_defaults(func=cmd_plan)

	sf = sub.add_parser("finish")
	sf.add_argument("--run-id", required=True)
	sf.add_argument("--outcome", required=True,
	                choices=["clean", "cycle-limit", "test-failure", "blocked", "abandoned"])
	sf.add_argument("--tier", choices=["fast", "full", "partial", "skipped"])
	sf.add_argument("--executed", help='JSON: {"<gate>":{"status":"done"|"skipped"|"failed","reason":"..."}}')
	sf.add_argument("--escalations", help='JSON list of {"gate":..,"reason":..}')
	sf.add_argument("--agents", help='JSON list of {"id":..,"model":..,"status":..,"findings":N}')
	sf.add_argument("--findings", help='JSON: {"auto_fix":N,"asked":N,"skipped":N}')
	sf.add_argument("--asks", type=int, default=0, help="unresolved ask-bucket items")
	sf.set_defaults(func=cmd_finish)

	sa = sub.add_parser("abandon")
	sa.add_argument("--run-id", required=True)
	sa.add_argument("--missing", required=True)
	sa.set_defaults(func=cmd_abandon)

	sc = sub.add_parser("check")
	sc.add_argument("--head")
	sc.add_argument("--run-id")
	sc.add_argument("--session", help="only runs this session started (default: $CLAUDE_CODE_SESSION_ID)")
	sc.set_defaults(func=cmd_check)

	ss = sub.add_parser("show")
	ss.add_argument("--run-id", required=True)
	ss.set_defaults(func=cmd_show)

	a = p.parse_args()
	sys.exit(a.func(a) or 0)


if __name__ == "__main__":
	main()
