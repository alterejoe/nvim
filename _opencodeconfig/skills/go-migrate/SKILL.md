---
name: go-migrate
description: "Migration conventions for golang-migrate using paired SQL up/down files. Covers file naming, the RLS transaction pattern, trigger-safe edits, schema conventions, and the backfill pattern. Load when writing or reviewing database migrations."
---

# Go Migrate

All database migrations use [golang-migrate/migrate](https://github.com/golang-migrate/migrate) CLI. Every migration MUST have a paired up and down file — no orphaned up migrations.

## File Naming

- **Format**: `{number}_{description}.up.sql` / `{number}_{description}.down.sql`
- Numbers are 4-digit sequential (0000, 0001, ...) — assigned by the migration workflow, not written by hand
- Descriptions are concise snake_case: `election_excluded`, `filingpaper_status`
- File header comment matches the filename: `-- 0098_election_excluded.up.sql`

Example names (number assigned at merge time):

```
election_excluded.up.sql
election_excluded.down.sql
```

## SQL Conventions

### Schema

- All tables in the `clerk` schema: `clerk.table_name`
- Always schema-qualify — never unqualified
- Quoting is optional: `clerk.table` or `"clerk".table`

### CREATE TABLE

```sql
CREATE TABLE clerk.election_batches (
    id               uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    state_id         uuid NOT NULL REFERENCES clerk.states (id),
    election_type_id uuid NOT NULL REFERENCES clerk.election_types (id),
    year             integer NOT NULL,
    name             text NOT NULL,
    election_date    date NOT NULL,
    created_at       timestamptz DEFAULT now() NOT NULL
);

CREATE INDEX idx_election_batches_state ON clerk.election_batches(state_id);
```

Rules:
- `DEFAULT` before `NOT NULL`
- `gen_random_uuid()` for PKs — never serial/identity
- `REFERENCES ... ON DELETE CASCADE` for child tables
- `timestamptz NOT NULL DEFAULT now()` for timestamps
- Named indexes with `idx_` prefix
- Explicit `CHECK` constraints with named constraint name

### INSERT (idempotent data)

```sql
INSERT INTO clerk.casbin_rule (id, p_type, v0, v1, v2, v3, v4, v5)
VALUES (md5('p:system:admin:/admin/*:GET'), 'p', 'system:admin', '/admin/*', 'GET', '', '', '')
ON CONFLICT (id) DO NOTHING;
```

- `md5(...)` for deterministic IDs where needed
- Always `ON CONFLICT DO NOTHING` for seed data
- Explicit column list — never bare `VALUES`

### ALTER TABLE — FK Cascade Change

```sql
ALTER TABLE clerk.elections DROP CONSTRAINT elections_batch_id_fkey;
ALTER TABLE clerk.elections
ADD CONSTRAINT elections_batch_id_fkey
    FOREIGN KEY (batch_id) REFERENCES clerk.election_batches (id) ON DELETE CASCADE;
```

- Drop → Add pattern for changing FK options
- `DROP CONSTRAINT IF EXISTS` when idempotency matters

### Data Backfill Pattern

Column add → populate → set NOT NULL, all in one RLS transaction:

```sql
BEGIN;
SET LOCAL app.user_id   = '00000000-0000-0000-0000-000000000000';
SET LOCAL app.user_name = 'system';
SET LOCAL app.user_email = 'system';

ALTER TABLE "clerk".county_contest_associations
    ADD COLUMN title varchar(255),
    ADD COLUMN valid_choices int;

UPDATE "clerk".county_contest_associations cca
SET title = cm.title, valid_choices = cm.valid_choices
FROM "clerk".contests_master cm
WHERE cca.contest_id = cm.id;

ALTER TABLE "clerk".county_contest_associations
    ALTER COLUMN title SET NOT NULL;

COMMIT;
```

## RLS Transaction Pattern

Tables with row-level security that check `app.user_id` require the system user context. Wrap ALL DML targeting these tables:

```sql
BEGIN;
SET LOCAL app.user_id   = '00000000-0000-0000-0000-000000000000';
SET LOCAL app.user_name = 'system';
SET LOCAL app.user_email = 'system';

-- DML operations (INSERT, UPDATE, DELETE, ALTER with data changes)

COMMIT;
```

System UUID: `00000000-0000-0000-0000-000000000000`

Pure DDL (CREATE TABLE, DROP TABLE, INDEX) typically does NOT need this context. Both up and down migrations use the same pattern when touching RLS table data.

## Trigger Disable Pattern

Some tables have protection triggers. Disable before modification, re-enable after:

```sql
ALTER TABLE clerk.casbin_rule DISABLE TRIGGER protect_system_roles;

DELETE FROM clerk.casbin_rule
WHERE id IN (md5('p:client:proofing:/auth/*:GET'), md5('p:client:proofing:/auth/*:POST'));

ALTER TABLE clerk.casbin_rule ENABLE TRIGGER protect_system_roles;
```

Known protected triggers:
- `protect_system_roles` / `protect_system_roles_update` on `clerk.casbin_rule`
- `audit_groups` on `clerk.groups`
- `audit_users` on `clerk.users`

## Down Migration Conventions

- Use SAME RLS/trigger-disabling pattern as the up migration
- `IF EXISTS` on all DROP for idempotent rollback
- Drop tables in reverse dependency order (children before parents)
- Delete data that was inserted by the up migration
- Drop constraints before dropping columns

```sql
BEGIN;
SET LOCAL app.user_id   = '00000000-0000-0000-0000-000000000000';
SET LOCAL app.user_name = 'system';
SET LOCAL app.user_email = 'system';

ALTER TABLE clerk.elections DROP CONSTRAINT elections_state_fkey;
UPDATE clerk.elections SET state = 'pending' WHERE state = 'awaiting_import';
ALTER TABLE clerk.elections
ADD CONSTRAINT elections_state_fkey FOREIGN KEY (state) REFERENCES clerk.election_state_types (id);
ALTER TABLE clerk.election_types DROP COLUMN initial;

COMMIT;
```

## Rules

1. **Every migration is a pair** — up creates, down reverses exactly. No unpaired files.
2. **Header comment** — first line is `-- {filename}` matching the actual file.
3. **Schema-qualify** all references: `clerk.table_name`, never bare.
4. **RLS tables** — `SET LOCAL` transaction for ALL DML, in both up and down.
5. **Protected triggers** — `DISABLE TRIGGER` before modification, `ENABLE TRIGGER` after. Both directions.
6. **Down is idempotent** — `IF EXISTS` on all DROP statements.
7. **Explicit column lists** in every DML — never `INSERT INTO t VALUES (...)`.
8. **`ON CONFLICT DO NOTHING`** for seed/idempotent inserts.
9. **`gen_random_uuid()`** for PKs — no serial types.
10. **Reverse dependency order** for table drops in down migrations.

## Workflow

1. Create `{next_number}_{description}.up.sql` and `.down.sql` in `migrations/migrations/`
2. Test: `make up` / `make down` from `migrations/` directory
3. The Makefile uses the `migrate` CLI with a dedicated `migrator` DB role
