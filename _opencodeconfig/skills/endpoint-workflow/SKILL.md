---
name: endpoint-workflow
description: "End-to-end workflow for building a new feature in the portal project. Covers the six-stage pipeline from scaffolding through implementation. Load when planning a new feature, adding routes, or understanding the build order."
---

# Endpoint Workflow

Building a new feature follows six stages in strict order. Do not start a stage until the prior one is complete and `go build ./...` is green.

## Stage 1 — Scaffold (forge)

Generate empty handler files and wire routes using forge HCL.

- Forge runs from project root, not inside server directories
- HCL lives at `.forge/{server}/{group}.hcl`
- Handler file naming: `{method}_{path_segments}.go` → function `{PascalCase}`
- GET and POST on the same path MUST have different function names and files
- Templ files must be `touch`-ed manually — forge tracks but doesn't create them
- After `forge apply`, verify `routes_gen.go` — it often misses nested routes

## Stage 2 — SQL + Query Wrappers (sqlc)

Write SQL, generate types, create Go wrappers.

1. Write SQL in `internal/sqlc/feature.sql`
2. Run `make sqlc`
3. Write Go wrapper in `internal/queries/feature.go`
4. Add request structs if needed
5. `go build ./...`

See the `query-pattern` skill for conventions.

## Stage 3 — Implement Handlers

Fill in the scaffolded handler bodies following the handler pattern.

- Every handler follows the fixed shape (Content-Type → ParseAndValidate → WithTx → Render)
- Use query wrappers, never direct sqlc calls
- DB failures use `usererr.UserMessage(err)`

See the `handler-pattern` skill for the full shape.

## Stage 4 — Write Templ Components

Build the UI using templ + gencomponents.

- Props structs defined in the same file as the component
- Interactive elements use gencomponents, layout stays raw HTML
- Flex chain on all scrollable list ancestors
- `data-autofocus` on outer panel, not search input

See the `templ-ui` and `gencomponents` skills.

## Stage 5 — Reconcile (if needed)

Fix any deviations from the standard pattern. Check:

- Stubs with TODO comments
- Direct `chi.URLParam` instead of `ParseAndValidate`
- Direct `q.SelectXxx` instead of query wrappers
- Hardcoded DB error strings instead of `usererr.UserMessage`
- Missing flash chains

## Stage 6 — Wire Navigation

Add nav entries for the new routes in the layout templ.

## Build Check Between Every Stage

```bash
cd {server} && go build ./...
```

Common errors:
- Undefined templ type → stub the props struct or write templ first
- Redeclared function → two files with same name, rename one
- Type mismatch → `db.ClerkXxx` vs `db.SelectXxxRow` after sqlc regen
- Missing import → handlers with DB work need: `db`, `queries`, `chi`, `uuid`, `pgtype`, `usererr`
