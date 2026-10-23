# looper

The review tooling behind the review-loop skill: run records, planning, the push gate, and PR reports.

## Language

**Risk**:
How likely a diff is to contain a costly defect, judged from the diff alone: attacker-reachable paths are high, logic or runtime changes are medium, everything else is low. Shown on PRs as a `risk:*` label.
_Avoid_: using it for the repo or path policy (that is the **review profile**)

**Review profile**:
Not built yet (designed in the looper Fieldnote). A declared policy for how heavily a part of a repo is reviewed, based on what a missed defect would cost there. The values are `light`, `standard` (today's behaviour) and `strict`.
_Avoid_: risk, stakes, heaviness

**Tier floor**:
The lightest review tier a run may use, set by `looper plan`. A review profile can lower it; the orchestrator never lowers it mid-run.

## Relationships

- **Risk** belongs to a diff. A **review profile** belongs to paths in a repo.
- A run's **tier floor** comes from its **risk** inputs, capped by the strictest **review profile** among the files it touches.
