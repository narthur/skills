# Security review prompt — not published

This file normally holds Anthropic's `/security-review` prompt, vendored out of the
Claude Code binary. It is **not distributed with this repo**: it is Anthropic's work,
not ours, and not ours to relicense.

Generate your own copy from your own installation before first use:

```bash
python3 ../upstream-check.py --extract > references/security-review.md
```

That gives you the prompt matching *your* installed Claude Code rather than a snapshot
of someone else's. `upstream-check.py` (Step 2a) then keeps it honest, reporting drift
whenever your binary moves ahead of the copy on disk.

Until you run it, the security review in Step 5 has no prompt to inject. Everything
else in the loop works.
