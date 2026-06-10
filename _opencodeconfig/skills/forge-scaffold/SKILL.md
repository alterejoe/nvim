---
name: forge-scaffold
description: "Scaffolding skill for the forge CLI generator. Takes a plan, analyzes what handlers exist vs need creating, writes HCL config, runs forge generate, and writes missing templ files. Designed to produce scaffolded files that are then filled out by subsequent processes."
---

# Forge Scaffold

## Overview

Forge is a code generator at the portal monorepo root that creates Go handler skeletons, templ UI stubs, and SQLC queries from HCL resource definitions.

The scaffolding pipeline:
1. **Plan** — user describes what handlers/features to build
2. **Analyze** — read `.forge/` HCL, `state.json`, and disk to find what already exists
3. **Generate** — write HCL, run `forge generate`, create missing templ files
4. **Report** — list what was created so follow-up processes can fill in details

Load this skill when adding new routes/handlers and you need to create the scaffolding first.

---

## Config Locations

| Thing | Path |
|---|---|
| Project root | `/home/jmeyer/projects/portal/` |
| Forge config | `.forge/` |
| Forge main HCL | `.forge/main.hcl` |
| Admin HCL files | `.forge/admin/{resource}.hcl` |
| Auth0 HCL files | `.forge/auth0/` |
| Client HCL files | `.forge/client/` |
| Forge state | `.forge/state.json` |
| Forge plan | `.forge/plan.json` |
| Import plan | `.forge/import-plan.json` |
| Templates | `/home/jmeyer/tools/forge_templates_portal/go-chi-templ-sqlc/templates/` |
| Protection file | `{server}/.forgo` |
| Makefile | `Makefile.forge` — `forge generate admin`, `forge plan`, etc. |

**For the admin server specifically:**

| File Type | Directory |
|---|---|
| Go handlers | `adminserver/internal/handlers/{resource}/{file}.go` |
| Templ UI | `adminserver/ui/html/{resource}/{file}.templ` |
| SQLC queries | `adminserver/internal/sqlc/{resource}.sql` |
| Route registration | `adminserver/cmd/routes_gen.go` |

---

## HCL Structure

Each resource file has `handler` and `templ` blocks:

```hcl
resource "elections" {
  server      = "admin"
  route_group = "elections"

  handler "get_admin_county_search" {
    route_method  = "get"
    handler_name  = "admin_county_search"
    handler_func  = "AdminCountySearch"
    chi_path      = "/county/search"
    convention    = "adminserver/internal/handlers/elections/get_admin_county_search.go"
    path_override = "adminserver/internal/handlers/elections/county-statecode-search.go"
    templ         = ["CountyList"]
  }

  templ "CountyList" {
    templ_func   = "CountyList"
    templ_file   = "county-statecodes"
    path_override = "adminserver/ui/html/elections/county-statecodes.templ"
  }
}
```

Key fields:
- **`handler` block label** — unique name, used as identity in `state.json`
- **`route_method`** — `get`, `post`, `put`, `delete`
- **`handler_name`** — snake_case identifier
- **`handler_func`** — PascalCase Go function name returned by the handler
- **`chi_path`** — URL pattern with `{param}` placeholders for path params
- **`convention`** — canonical path (auto-named by forge convention)
- **`path_override`** — actual file path used on disk (overrides convention)
- **`templ`** — list of templ component names this handler renders
- **`path_params`** — URL params from `chi_path` (auto-detected by forge from `{param}`)

For templ blocks:
- **`templ_func`** — PascalCase templ function name
- **`templ_file`** — filename without extension (used for `{name}.templ`)
- **`path_override`** — actual file path

---

## Workflow

### Phase 1: Read Current State

Read these files to build a picture of what exists:

1. `.forge/admin/*.hcl` — all resource definitions and their handlers
2. `.forge/state.json` — which handlers/templs have been applied and when
3. Disk check — scan `adminserver/internal/handlers/{resource}/` and `adminserver/ui/html/{resource}/` for existing files

### Phase 2: Accept Plan

The user describes what to build. Extract:
- **Server** — which server (typically `admin`)
- **Resource** — the resource group (e.g., `elections`, `users`, `auth0api`)
- **Route group** — typically the same as resource
- **Handlers** — list of:
  - HTTP method (`get`, `post`, `put`, `delete`)
  - URL path (chi format with `{params}`)
  - Handler function name (PascalCase)
  - Handler filename (using `path_override` for readable names)
  - Templ components needed (list of component names)
  - Path params (extracted from `chi_path`)

### Phase 3: Gap Analysis

For each handler in the plan, check:
1. **Exists in HCL?** — handler block present in the resource file
2. **Exists on disk?** — file at `path_override` exists
3. **In state.json?** — entry present with `applied_at` timestamp

For each templ in the plan:
1. **Exists in HCL?** — templ block present
2. **Exists on disk?** — `.templ` file at `path_override` exists

Determine status:
- **`missing_hcl`** — needs HCL block added
- **`missing_file`** — file doesn't exist (scaffold needed)
- **`out_of_sync`** — HCL doesn't match disk
- **`exists`** — all good

### Phase 4: Generate Scaffolding

For each handler that needs creation:

**Step 1 — Add HCL block**
Add a `handler` block to the appropriate `.forge/admin/{resource}.hcl` file. Use descriptive `path_override` names that are easy to `gf` to in Neovim.

For path params, know that forge auto-extracts `{param}` from `chi_path`, so just include the params in the URL pattern.

Convention for path_overrides:
- GET single-page renders: `{feature-name}.go` (e.g., `county-statecodes.go`)
- POST handlers: `{feature-name}-post.go`
- PUT handlers: `{feature-name}-put.go`
- DELETE handlers: `{feature-name}-delete.go`
- Row/search partials: `{feature-name}-row.go`, `{feature-name}-search.go`
- Edit forms: `{feature-name}-edit.go`, `{feature-name}-edit-form.go`

**Step 2 — Add templ blocks (if needed)**
Add `templ` blocks for each referenced templ component. Use `path_override` to control where the `.templ` file lives.

**Step 3 — Run forge generate**
```bash
cd /home/jmeyer/projects/portal
forge generate admin
```
This creates handler Go files from `handler.go.tmpl` and templ files from `templ.templ.tmpl`.

**Step 4 — Create missing templ files**
Forge's templ template generation may not reliably create `.templ` files. Check and create any missing ones manually. The template produces:

```templ
package {route_group}

type {TemplFunc}Props struct {
	// TODO: define props
}

templ {TemplFunc}(props *{TemplFunc}Props) {
	<div>
		// TODO: implement {name} view
	</div>
}
```

### Phase 5: Verify

1. Check `adminserver/cmd/routes_gen.go` for the new route registrations (forge may miss nested routes — verify and fix manually if needed)
2. Check that handler files exist at `path_override` paths
3. Check that templ files exist at corresponding paths
4. Run `go build ./...` in the server directory

### Phase 6: Report

Output a structured report showing:
- Handlers created (file paths)
- Templ files created (file paths)
- Routes registered
- Orphan risks (functions in existing files that aren't in HCL — visible in `import-plan.json`)

---

## Naming Conventions

**path_override names** (for `gf`-ability):

| Pattern | Example |
|---|---|
| `{feature}.go` | `county-statecodes.go` |
| `{feature}-post.go` | `county-statecodes-post.go` |
| `{feature}-put.go` | `county-statecodes-put.go` |
| `{feature}-delete.go` | `county-statecodes-delete.go` |
| `{feature}-edit.go` | `county-statecodes-edit.go` |
| `{feature}-row.go` | `county-statecode-row.go` |
| `{feature}-search.go` | `county-statecode-search.go` |
| `{feature}-add.go` | `add-county-statecode.go` |

Don't use the conventional (auto-generated) name. Always set `path_override` to something readable.

**handler_func** naming: `{RouteGroup}{PascalPathSegments}` — e.g., `AdminCountyStatecodesRowStateCodeId`

---

## Common Pitfalls

1. **Templ files not created** — forge tracks templ blocks but may not write `.templ` files. Always verify and create manually if missing.
2. **Routes_gen.go misses nested routes** — forge's `routes_gen.go.tmpl` generates package `handlers` but the project uses package `main`. The route registration is partially manual. Verify after generation.
3. **path_override collisions** — two handlers mapping to the same file will cause the last one to overwrite. Each handler needs a unique file.
4. **Orphan functions** — `import-plan.json` lists functions in existing files that aren't defined in HCL. Don't delete these — they're real implementations. Note them in the report.
5. **Handler func name conflicts** — GET and POST on the same path must have different function names (even if they have separate files). Use `{Name}` for GET and `{Name}Post` for POST.
6. **Path params in chi_path** — forge auto-extracts `{param}` from URL patterns. Don't add `path_params` manually unless they need different types (the template defaults to UUID).
7. **Handler names in state.json** — the handler block label is used as the identity key. Changing it will create a duplicate in forge's view.

---

## Template Output Reference

### handler.go.tmpl output
```go
package {route_group}

import (
	"net/http"
	// path_params imports: chi, uuid, pgtype
	// templ imports: ui/html/{route_group}
	"{module}/internal/app"
)

func {handler_func}(a *app.App) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		// path param extraction
		// ParseForm for POST/PUT
		// render first templ
	}
}
```

### templ.templ.tmpl output
```templ
package {route_group}

type {TemplFunc}Props struct {
	// TODO: define props
}

templ {TemplFunc}(props *{TemplFunc}Props) {
	<div>
		// TODO: implement {name} view
	</div>
}
```

### sqlc.sql.tmpl output
```sql
-- name: {Method}{RouteGroup}{HandlerNamePascal} :one
SELECT * FROM {route_group}.{route_group} WHERE id = $1;
```

### routes_gen.go registration format
```go
r.Route("/admin/{resource}", func(r chi.Router) {
	r.Get("/{path}", {pkg}.{HandlerFunc}(a))
	r.Post("/{path}", {pkg}.{HandlerFunc}(a))
})
```

The real `routes_gen.go` uses chi `Route` + `Group` for auth middleware, with `JwtOnlyMiddleware` for unauthenticated routes and `RequireAuthentication` + `CasbinRBACMiddleware` for protected routes. Match the existing patterns.
