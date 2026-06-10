---
name: query-pattern
description: "SQLC query conventions for a Go/chi/templ stack. Covers SQL file structure, sqlc.arg naming, query wrapper signatures, error wrapping, UPDATE...FROM joins, request struct placement, and the make sqlc workflow. Load when writing SQL queries, creating query wrappers, or debugging sqlc generation issues."
---

# Query Pattern

All database access goes through two layers: raw SQL in `.sql` files (processed by sqlc) and Go wrapper functions in `internal/queries/`.

## SQL File Rules

- Always write SQL to `internal/sqlc/*.sql` files — `make sqlc` replaces everything in `db/`
- Use `sqlc.arg(name)` for parameters — never `$1`, `$2`
- Aliases required when joining: `g.id AS group_id`, not `g.id`
- Every query needs an annotation: `:one`, `:many`, or `:exec`
- `make sqlc` does a live schema dump — functions not in `.sql` files disappear after regeneration

```sql
-- name: SelectContestsFromGroupID :many
SELECT
    c.id AS contest_id,
    c.title,
    c.type,
    g.name AS group_name
FROM clerk.contests c
JOIN clerk.groups g ON g.id = c.group_id
WHERE c.group_id = sqlc.arg(group_id);
```

## UPDATE Queries with Joined RETURNING

When an UPDATE needs to return data from a joined table, use `FROM` clause and join on the NEW parameter value, not the pre-update column:

```sql
-- name: UpdateGroup :one
UPDATE clerk.groups g
SET name = sqlc.arg(name), state_id = sqlc.arg(state_id)
FROM clerk.states s
WHERE g.id = sqlc.arg(id) AND s.id = sqlc.arg(state_id)
RETURNING g.id, g.name, s.abbreviation;
```

The join condition `s.id = sqlc.arg(state_id)` uses the NEW value being set, not `g.state_id` which still holds the old value during the UPDATE. This is a common source of bugs — the RETURNING data comes from the wrong state if you join on the pre-update column.

## Go Wrapper Conventions

Wrappers live in `internal/queries/`. They are the only code that calls `q.SelectXxx` directly.

```go
// Signature: ctx first, q *db.Queries last
// 1-2 params positional, 3+ use a named struct
func SelectContestsFromGroupID(ctx context.Context, id pgtype.UUID, q *db.Queries) ([]db.SelectContestsFromGroupIDRow, error) {
    rows, err := q.SelectContestsFromGroupID(ctx, id)
    if err != nil {
        return nil, fmt.Errorf("SelectContestsFromGroupID(database query): %w", err)
    }
    return rows, nil
}

// Exec (no return value)
func UpdateContestControlled(ctx context.Context, contestID, statecodeID pgtype.UUID, controlled bool, q *db.Queries) error {
    if err := q.UpdateContestControlled(ctx, db.UpdateContestControlledParams{...}); err != nil {
        return fmt.Errorf("UpdateContestControlled(database update): %w", err)
    }
    return nil
}
```

## Error Wrapping

Format: `"FuncName(operation): %w"` — always `%w` not `%s` so `errors.Is`/`errors.As` work through the chain.

Operations: `database query`, `database insert`, `database update`, `database delete`.

## Assert Helpers

For existence checks that should fail hard:

```go
func AssertGroupExists(ctx context.Context, id pgtype.UUID, q *db.Queries) error {
    _, err := q.SelectGroupByID(ctx, id)
    if err != nil {
        return fmt.Errorf("AssertGroupExists: group %s not found: %w", id.Bytes, err)
    }
    return nil
}
```

## Request Structs

Request structs that pair with a specific wrapper live in `internal/queries/` next to the wrapper. Handler-only structs live in the handler file. Shared structs go in `types.go`.

## Workflow

1. Write SQL in `internal/sqlc/feature.sql`
2. Run `make sqlc` — regenerates all `db/*.go` files
3. Write Go wrapper in `internal/queries/feature.go`
4. If wrapper needs a request struct, add it in the same file
5. Build check: `go build ./...`

## Common Gotchas

- After `make sqlc`, previously generated functions not in `.sql` files disappear — check for compilation errors
- `pgtype.UUID` not `uuid.UUID` for sqlc-generated types
- Nullable columns generate `pgtype.Text`, `pgtype.Int4`, etc. — access `.String`, `.Int32`, `.Valid`
- Enum types generate as Go string types — use the generated constants
