---
name: architecture
description: "Baseline architecture tenets for structuring projects: deep modules, lean on framework convention, monorepos for code that changes together, a services layer around external dependencies, raw SQL over optional ORMs, functional style, no premature abstraction. Use whenever making a structural decision — starting a project or package, adding a dependency, choosing data access, laying out folders, deciding whether to abstract, or splitting/merging repos."
---

# Architecture

A baseline for how projects are structured. Each tenet is labelled:

- **Default** — do this unless there is a stated reason not to. Name the reason when departing.
- **Consideration** — weigh it; no justification needed to skip.

**Existing repos win.** When a repo already contradicts a tenet (it uses an ORM, it has a different layout), follow the repo and flag the conflict in one line. Don't refactor toward these tenets unprompted.

Tenets are language-agnostic; examples are TypeScript.

## 1. Deep modules — default

A lot of behaviour behind a small interface, at a clean seam, tested through that interface. Use the vocabulary and process in the `codebase-design` skill ([mattpocock/skills](https://github.com/mattpocock/skills)) rather than restating it here.

## 2. Lean on convention — default

Don't fight the framework and don't reinvent the wheel. When a framework has a conventional way to do something — layout, data access, routing, config — use it. **Framework convention beats every tenet below when they collide.**

## 3. Monorepo for code that changes together — default

If two packages are likely to change in the same PR, they belong in one repo.

- Native workspaces (pnpm / npm / bun). Add Turborepo only once build times hurt.
- Split into a separate repo only when **visibility or ownership** differs (public vs private, different team). Different deploy cadence alone is not a reason — workspaces deploy independently.

## 4. Services layer around external dependencies — default

Every external dependency gets one module at `src/services/<service>/index.ts`. Callers never import the SDK, driver, or HTTP client directly.

- **Behind a service:** database, third-party APIs/SDKs, email/SMS, queues, caches.
- **Consideration:** filesystem, clock, randomness, env — wrap only when a test needs to control them.
- Services export **domain-shaped functions** (`getInvoice(id)`, `markPaid(id)`), not a thin client. All SQL / SDK calls stay inside.
- A large service splits into internal files re-exported from the index:

  ```
  src/services/db/index.ts      // export * from './invoices', './users'
  src/services/db/client.ts     // connection
  src/services/db/invoices.ts   // getInvoice, markPaid
  ```

- No interface/port until a second adapter (usually a test fake) actually exists. The module boundary is the protection.

## 5. Skeptical of ORMs — default

Where an ORM is optional (Node/TS, Go, etc.), don't add one. Write raw SQL through the driver, wrapped in typed functions inside the db service.

- **Upgrade trigger:** move to a typed query builder ([Kysely](https://kysely.dev)) when queries become dynamic (optional filters/sorts built at runtime) or hand-asserted result types start drifting from the schema. Kysely type-checks queries against the schema and infers results, while staying close to SQL.
- **Exception:** in ORM-native frameworks (Rails/ActiveRecord, Django, Laravel/Eloquent), use the framework's ORM — tenet 2 wins.

## 6. Plain SQL migrations — default

Migrations are plain `.sql` files, not generated from a model layer.

## 7. Colocate by feature — default

Group code by feature (`billing/`), not by layer (`controllers/`, `models/`). Where the framework dictates layout (Next `app/`, SvelteKit routes), follow it; otherwise `src/<feature>/`.

## 8. Validate at the edges — default

Parse untrusted input at trust boundaries (request handlers, webhooks, external API responses, env) into typed values — e.g. with zod. Inside the boundary, trust the types; don't re-validate.

## 9. Functional style — default (yields to strong convention)

- Functions and plain data over classes.
- Pure core, effects at the edges: business logic takes data and returns data; I/O happens in services and handlers. This pairs with tenet 4 — services do the effects, features stay pure.
- Immutable data: don't mutate arguments or shared state; return new values.

Where a framework's convention is class-based or mutable (Angular services, ActiveRecord models), follow the framework.

## 10. No premature abstraction — default

Abstract only when either:

- the pattern is well defined — the repetition has occurred **three or more times**; or
- a **cited** roadmap shows the abstraction will make planned work more efficient. Cite it: an open issue, a spec, a project note, or the user saying so in the session. "We'll probably need this" is not a roadmap.

Until then, duplicate.
