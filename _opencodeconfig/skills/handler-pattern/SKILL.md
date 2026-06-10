---
name: handler-pattern
description: "Go HTTP handler conventions for a chi/templ/sqlc stack. Covers ParseAndValidate, WithTx, flash chain, usererr, request structs, action handler pattern, and HTMX redirects."
---

# Handler Pattern

Every HTTP handler follows a fixed structure. Deviations cause bugs.

## The Shape

```go
func GetXxx(a *app.App) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "text/html")  // always first

        var req queries.XxxRequest
        if err := a.Validator.ParseAndValidate(r, &req, map[string]string{
            "groupID":    chi.URLParam(r, "groupID"),
            "search":     r.URL.Query().Get("search"),
        }); err != nil {
            a.Flash.Flash(w, "error", "Invalid request").Log(err).Status(http.StatusBadRequest)
            return
        }

        uid, _ := uuid.Parse(req.GroupID)
        pgID := pgtype.UUID{Bytes: uid, Valid: true}

        var result SomeType
        if err := a.WithTx(r.Context(), app.RLSUser, func(q *db.Queries) error {
            var err error
            result, err = queries.SelectXxx(r.Context(), pgID, q)
            return err
        }); err != nil {
            a.Flash.Flash(w, "error", usererr.UserMessage(err)).Log(err).Status(http.StatusInternalServerError)
            return
        }

        props := pkg.XxxProps{Data: result}
        a.RenderPage(w, r, pkg.Xxx(&props))
    }
}
```

## Logging (Mandatory)

Every error path MUST include `.Log(err)`. The Flash chain's `.Log()` produces two log lines:

1. `ERROR <user message>` with `caller="internal/handlers/xxx.go:42"` and `err="<detail>"`
2. Full goroutine stack trace for deep traceability

This means:
- The flash message stays short and user-friendly
- Developers see exactly which handler line triggered the error plus the full call chain (WithTx → query wrapper → SQLC → database driver)
- No separate `a.Logger.Error(...)` calls allowed inside handlers

**The `.Log().Status()` chain is the single logging mechanism for all handler errors.**

## Rules

1. `Content-Type: text/html` is the first line — before any branching
2. ALL inputs go through `ParseAndValidate` — URL params, query params, form fields all in one map. Never use `chi.URLParam` or `r.URL.Query().Get` directly in the handler body
3. Three variants: `ParseAndValidate` (form/URL), `ParseAndValidateJSON` (JSON body), `ParseAndValidateMultipart` (file upload)
4. Type conversion happens after validation — `uuid.Parse` without error check (validation already confirmed it's a UUID)
5. All DB work inside `a.WithTx` with an RLS role
6. Inside WithTx, only call wrappers from `internal/queries/` — never `q.SelectXxx` directly
7. DB failure flash always uses `usererr.UserMessage(err)` — never hardcoded strings for DB errors
8. Hardcode strings only for: validation failures ("Invalid request"), not-found after successful operation, missing required files
9. HTMX redirect after POST: `w.Header().Set("HX-Redirect", url)` + `w.WriteHeader(http.StatusOK)` — never `http.Redirect`
10. **Mandatory logging — every error path must log.** Every `a.Flash.Flash(...)` must chain `.Log(err)`. The `.Log()` call is the only allowed logging mechanism inside handlers — never use raw `a.Logger.Error(...)` or `a.Logger.Info(...)`.
11. **Logging audit rule.** Before shipping any handler, verify every `return` statement (except the final success render) has a preceding `.Log(err).Status(code)` call. Zero-log handlers are rejected.

## Request Structs

```go
type XxxRequest struct {
    GroupID    string `schema:"groupID"    validate:"required,uuid"`
    Controlled string `schema:"controlled" validate:"required,oneof=true false"`
    Search     string `schema:"search"     validate:"omitempty"`
}
```

- `schema` tags for form/URL, `json` tags for JSON
- All fields are strings — convert after validation
- Boolean query params: `string` + `validate:"required,oneof=true false"` → convert with `req.Field == "true"`
- Placement: paired with query wrapper → `internal/queries/`. Handler-only → handler file. Shared → `types.go`
- Naming: `{Entity}{Action}Request`

## Action Handler Pattern

When an action modifies one record and returns that row:

```go
var rows []db.SelectXxxRow
if err := a.WithTx(r.Context(), app.RLSUser, func(q *db.Queries) error {
    if err := queries.UpdateXxx(r.Context(), pgID, controlled, q); err != nil {
        return err
    }
    var err error
    rows, err = queries.SelectXxxList(r.Context(), pgGroupID, q)
    return err
}); err != nil {
    a.Flash.Flash(w, "error", usererr.UserMessage(err)).Log(err).Status(http.StatusInternalServerError)
    return
}

var updated *db.SelectXxxRow
for i, row := range rows {
    if row.ID == pgTargetID {
        updated = &rows[i]
        break
    }
}
```

The pattern is: update → re-fetch full list in same TX → find by ID → render single row. This ensures the re-rendered row has consistent data from the same transaction.

## Flash Chain

```go
a.Flash.Flash(w, "category", "message").Log(err).Status(http.StatusXxx)
```

- Categories: "error", "success", "warning", "info"
- `.Log(err)` logs the error with handler source and full stack trace. Pass `nil` if no underlying error (rare — almost always there is one).
- `.Status(code)` sets response status
- Always end with `return`
- **Mandatory:** Every Flash call must include `.Log(err)` — no exceptions. This is the only logging mechanism inside handlers.

## Deprecated — Do Not Use

- `ParseParams` → replaced by `ParseAndValidate`
- Direct `chi.URLParam` in handler body → goes through ParseAndValidate map
- Hardcoded DB error strings → `usererr.UserMessage(err)`
- `http.Redirect` for HTMX → `HX-Redirect` header
- Direct `q.SelectXxx` calls → query wrappers in `internal/queries/`
- `a.Logger.Error(...)` / `a.Logger.Info(...)` inside handlers → Flash chain `.Log(err)` only
