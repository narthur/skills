#!/usr/bin/env python3
"""Read the run record — what actually happens across review-loop runs.

A record with no consumer is the write-only-log failure already logged against
friction.md (three defects were one-line entries there and recurred anyway,
because nothing converted an entry into a fix). So there are two consumers:

  review-stats.py            ad-hoc, when you want to know
  review-stats.py --alarm    called by plan.py at Step 0, one line or silence

The alarm exists because repeat count beats calendar. A gate dropped three times
is a stronger signal than "it is time for a batch review", and Step 0 is the one
moment you are already in the skill and would act on it.
"""
import argparse
import collections
import json
import os
import sys

STORE = os.path.expanduser(
	os.environ.get("REVIEW_LOOP_RUNS") or "~/.claude/review-loop/runs.jsonl")
ALARM_THRESHOLD = 3
ALARM_WINDOW = 50


def load():
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
					continue
				rid = rec.get("run_id")
				if rid:
					runs.setdefault(rid, {}).update(rec)
	except FileNotFoundError:
		return []
	return sorted(runs.values(), key=lambda r: r.get("planned_at") or "")


def dropped_gates(run):
	"""Gates planned to run that did not report done."""
	planned = {g for g, v in (run.get("gates") or {}).items()
	           if isinstance(v, dict) and v.get("planned") == "run"}
	executed = run.get("executed") or {}
	out = {}
	for g in planned:
		st = (executed.get(g) or {}).get("status") if isinstance(executed.get(g), dict) else None
		if st != "done":
			out[g] = st or "unreported"
	return out


def cmd_alarm(runs):
	recent = runs[-ALARM_WINDOW:]
	counts = collections.Counter()
	for run in recent:
		if run.get("outcome") == "abandoned":
			counts["(run abandoned)"] += 1
		for g in dropped_gates(run):
			counts[g] += 1
	hits = [(g, n) for g, n in counts.most_common() if n >= ALARM_THRESHOLD]
	if not hits:
		return 0
	print(f"review-loop alarm — over the last {len(recent)} runs:")
	for g, n in hits:
		print(f"  {g} did not complete {n}x")
	print("  Repeat count beats calendar: fix the gate or change the plan, don't log it again.")
	return 0


def cmd_report(runs, repo):
	if repo:
		runs = [r for r in runs if repo in (r.get("repo") or "")]
	if not runs:
		print("no runs recorded")
		return 0
	fin = [r for r in runs if r.get("outcome")]
	print(f"runs: {len(runs)}  finished: {len(fin)}  unfinished: {len(runs) - len(fin)}")

	def tally(label, key):
		c = collections.Counter(r.get(key) or "(unset)" for r in runs)
		print(f"\n{label}: " + "  ".join(f"{k}={v}" for k, v in c.most_common()))

	tally("outcome", "outcome")
	tally("tier floor", "tier_floor")
	tally("tier executed", "tier_executed")
	tally("session kind", "session_kind")
	tally("orchestrator model", "orchestrator_model")

	drops = collections.Counter()
	by_model = collections.defaultdict(collections.Counter)
	by_kind = collections.defaultdict(collections.Counter)
	for r in runs:
		for g in dropped_gates(r):
			drops[g] += 1
			by_model[r.get("orchestrator_model") or "(unset)"][g] += 1
			by_kind[r.get("session_kind") or "(unset)"][g] += 1
	if drops:
		print("\ngates planned but not completed:")
		for g, n in drops.most_common():
			print(f"  {n:3d}  {g}")
		print("\n  by orchestrator model:")
		for m, c in sorted(by_model.items()):
			print(f"    {m}: " + ", ".join(f"{g}×{n}" for g, n in c.most_common(4)))
		print("  by session kind:")
		for k, c in sorted(by_kind.items()):
			print(f"    {k}: " + ", ".join(f"{g}×{n}" for g, n in c.most_common(4)))

	esc = collections.Counter(
		e.get("gate") or "(unnamed)"
		for r in runs for e in (r.get("escalations") or []) if isinstance(e, dict))
	if esc:
		print("\nescalations above the computed floor (thresholds may be too loose):")
		for g, n in esc.most_common():
			print(f"  {n:3d}  {g}")

	asks = sum(r.get("unresolved_asks") or 0 for r in runs)
	if asks:
		print(f"\nunresolved ask-bucket items across all runs: {asks}")
	return 0


def main():
	p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	p.add_argument("--alarm", action="store_true", help="print only repeat-offender gates; silent when clean")
	p.add_argument("--repo", help="filter to runs whose repo path contains this")
	a = p.parse_args()
	runs = load()
	sys.exit(cmd_alarm(runs) if a.alarm else cmd_report(runs, a.repo))


if __name__ == "__main__":
	main()
