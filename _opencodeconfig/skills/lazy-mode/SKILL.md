---
name: lazy-mode
description: Full-file-only delivery with structural parity verification, verbose-logging enforcement, AI context gate, convention-first reuse, and strict scope discipline. No partials, no splices, no off-script changes.
---

# Lazy Mode

**Load this skill when:** You want full file replacements only — ready to copy, paste, and reload. No partials, no blocks, no "splice this into line 42." You want to read the code and understand what's happening without hunting through diffs.

This skill is a stricter superset of `code-delivery` with structural parity verification, explicit verbose-logging enforcement, AI context gate, convention-first reuse, and strict scope discipline. It does not replace `code-delivery` — it owns the more restrictive variant.

**Who this is for:** You know what you're doing. You're generating full files for process efficiency, not because you need help understanding the code. The AI's job is to produce complete, pasteable files that follow established conventions — nothing more, nothing less.

---

## Core Rule — Full Files Only

Every code block is a **complete file**. No exceptions.

| What you get | Never happens |
|---|---|
| `Full replacement:` — entire file content | Partial snippets |
| `New file:` — brand new file | Block delivery (function-only, struct-only) |
| | `// ... rest unchanged` |
| | Descriptions of what to change |
| | "Here's the approach, you write it" |

**If a change is tiny** (one line in a 300-line file) — you still get the full file. The copy-paste overhead is trivial. The risk of a bad splice is not.

### Structural Parity Verification (Hard Requirement)

**Before shipping any `Full replacement:` block, verify the replacement is actually complete.** The label means the entire file — all functions, all structs, all imports, all templ components. A "full replacement" with half the data is a lie.

**Verification steps (mandatory, every time):**

1. **Read the full original file** — every line, not a grepped chunk. Use `read` with the actual file path, no offset, no limit.
2. **Count structural elements before the change:**
   - Functions (`func `)
   - Methods (`func (`)
   - Structs (`type ... struct`)
   - Templ components in `.templ` files (`templ `)
   - Const blocks (`const (`)
   - Var blocks (`var (`)
   - Import statements in the import block
3. **Count the same in the replacement.**
4. **Verify parity:** `original_count + added - removed == replacement_count`
   - If adding 1 function: replacement should have `original + 1` functions
   - If removing 1 function: replacement should have `original - 1`
   - If modifying only a function body: replacement should have the **same** count
5. **Line count sanity check:** Replacement lines should not be wildly shorter than the original (accounting for additions/removals). If the original is 300 lines and the "full replacement" is 45 lines — something was dropped.
6. **If mismatch found:** Re-read the original file in full. Fix the replacement. Re-count. Ship.

**Example verification:**

```
Original file: handlers/group.go
  - 7 func declarations
  - 2 type structs
  - 1 const block
  - 312 lines total

Change: add DeleteMember handler (+1 func, ~40 lines)

Replacement: handlers/group.go
  - 8 func declarations ✅ (7 original + 1 added)
  - 2 type structs ✅ (unchanged)
  - 1 const block ✅ (unchanged)
  - 349 lines ✅ (~312 + 40)

→ Parity verified. Ship.
```

**Counter-example (rejected):**

```
Original file: handlers/group.go
  - 7 func declarations
  - 312 lines total

Replacement: handlers/group.go (labeled "Full replacement")
  - 2 func declarations ❌ (5 missing!)
  - 98 lines ❌ (214 lines missing!)

→ Parity failed. Re-read original. Do NOT ship.
```

### When a File Is Too Large to Read

If the file exceeds the `read` tool's limit (2000 lines), use multiple `read` calls with offsets to capture everything. Verifying structural parity across a large file is even more critical — large files are exactly where partial drops happen unnoticed.

---

## AI Context Gate & File Size Evaluation

### The Problem

Lazy-mode delivers **full files only**. Full-file delivery is reliable only when files are small enough for the AI to process in context. When a file grows beyond working range, the AI either drops structural elements (parity failure) or bloats the response with thousands of lines the user didn't ask to change.

The fix is twofold:
1. **Proactive modularization** — split files before they hit the gate so they stay small
2. **Hard gate** at 750 lines — no more silent growth

### Gate Rules

| Situation | Behavior |
|---|---|
| Existing file ≤500 lines | Full file replacement ✓ |
| Existing file 500–749 lines | Run File Size & Modularization Evaluation. If a clean domain split exists, propose it proactively — don't wait for it to hit the gate. Otherwise full file replacement is fine. |
| Existing file ≥750 lines, change is **substantial** | **Hard stop.** Must split before making the change. Propose a domain-coherent split. Do not generate any code until the split is resolved. |
| Existing file ≥750 lines, change is **trivial** (single line, rename, small constant) | Evaluate modularization first. If a clean domain split exists, propose it — don't silently generate a bloated full file. Only generate the full file if split is genuinely impossible. Append note with size + eval result. |
| New file would be ≥750 lines | **Hard stop.** Must split into multiple files before creation. |
| Same large file encountered **repeatedly across changes** | Modularization is overdue. Propose the split immediately — don't wait for the next gate hit. |

**Example of a "substantial" change:** Adding a new handler function, modifying query logic, restructuring a component. Anything that touches the file's structure or adds meaningful logic.

**Example of a "trivial" change:** Fixing a typo in a string literal, updating a constant value, adding a single-line import.

### File Size & Modularization Evaluation

**This evaluation runs before every change to a file >500 lines.** It determines whether modularization should happen before the change.

#### Decision Flow

```
File >500 lines → Evaluate modularization
 │
 ├─ Can the file be split at domain boundaries
 │  into files ≤500 lines each?
 │  │
 │  ├─ YES → Propose the split. Make the change
 │  │        in the resulting smaller files using
 │  │        full replacements going forward.
 │  │        Each file will be ≤500 lines — well
 │  │        within the reliable range.
 │  │
 │  └─ NO (single-responsibility, coherent unit):
 │       │
 │       ├─ File ≥750 lines + substantial change?
 │       │  → Must split anyway. Hard stop.
 │       │    Find a different boundary or restructure.
 │       │
 │       └─ Otherwise:
 │            → Full file replacement is the fallback.
 │              ⚠️ Note: "File is N lines — modularization
 │                 was evaluated but no clean split exists."
 │              Include line-numbered context in the
 │              delivery comment so the user can navigate
 │              to the changed area if needed.
```

#### What "Modularization" Means

Splitting a file at **domain boundaries**, not function-type boundaries:

```
✅ Correct — domain split:
  handlers/contest.go (600 lines)
    → handlers/contest_create.go (200 lines)
    → handlers/contest_list.go (180 lines)
    → handlers/contest_manage.go (220 lines)

❌ Wrong — function-type split:
  handlers/contest.go
    → handlers/contest_types.go (structs)
    → handlers/contest_routes.go (mux setup)
    → handlers/contest_handlers.go (handler funcs)
```

Each resulting file must be **coherent, readable top-to-bottom, and ≤500 lines**.

#### When the Evaluation Says "Split"

```
⚠️ group.go is at 820 lines and hit the AI context gate.
File Size & Modularization Evaluation: a clean domain split exists.

Recommended split:
  group_access.go (permissions, invitations — ~350 lines)
  group_members.go (roster, roles — ~300 lines)
  group_settings.go (configuration — ~170 lines)

Each would be well within working range.
Want me to split now before making this change?
```

#### When the Evaluation Says "Can't Split" but File Is Large

```
⚠️ auth.go is 740 lines. Evaluated modularization — no clean domain
split exists (single authentication service, all handlers share
session state and middleware). Full file replacement proceeding.
Consider a service-layer refactor if it crosses 750.
```

### Split Strategy

**Similar handlers belong together in one file.** That's correct grouping. Don't fight it.

When splitting, **split at natural domain boundaries** — never by function type:

```
✅ Correct — domain split:
  handlers/group.go (450 lines — access + members)
    → handlers/group_access.go (250 lines)
    → handlers/group_members.go (200 lines)

❌ Wrong — function-type split:
  handlers/group.go
    → handlers/group_types.go (structs)
    → handlers/group_routes.go (mux setup)
    → handlers/group_handlers.go (handler funcs)
```

The split should produce files that an AI (and a human) can read top-to-bottom and understand the full feature. Each file tells a complete story about one domain.

### Exempt from the Gate

These file types don't trigger the 750-line gate:

- SQL migrations and seed files
- Configuration files (YAML, JSON, TOML, .env)
- CSS / SCSS
- Markdown documentation
- Generated code (SQLC output in `db/`, `gen/`, anything from `go generate`)
- Large generated data structures (enums, constants auto-generated by tooling)

**SQLC generated files are never modified.** If a generated file seems wrong, the source SQL is wrong — fix the SQL, regenerate.

---

## Convention-First Reuse

Before writing anything, **confirm an existing pattern doesn't already solve it.** Most requests map to something already in the codebase.

### What to Check

1. **Handler pattern** — Is there an existing handler that does the same shape of work? Copy its structure.
2. **Query pattern** — Is there a similar SELECT/UPDATE/INSERT? Use the same SQLC wrapper signature.
3. **UI components** — Is there a gencomponent variant that covers the interaction? Use it — don't write raw HTML.
4. **Form behavior** — Is there a similar validation constraint pattern? Reuse the constraint strings.
5. **HTMX interaction** — Is there an existing POST→poll→restore page? Clone the lifecycle.
6. **Keymap panel** — Is there a list/detail page with keyboard nav? Match the panel numbering.

### Anti-Patterns

- Writing a raw `<button onclick>` when a gencomponent `Button` variant exists
- Inventing new handler structure when 15 handlers in the same file already do it one way
- Creating a new query wrapper pattern when the convention is established in `internal/queries/`
- Using `http.Redirect` for HTMX — the handler-pattern skill says `HX-Redirect` header

### Pragmatic Reuse

Don't cargo-cult inappropriate patterns. If the existing pattern genuinely doesn't fit (different lifecycle, different concurrency model), say so and propose the adjusted approach. But the burden of proof is on deviation — default to reuse.

---

## Strict Scope Discipline

**Only generate what was explicitly requested.** Nothing else.

| Rule | Meaning |
|---|---|
| No "nice to have" | If it wasn't in the ask, it doesn't go in. |
| No "simple improvements" | A cleaner approach that wasn't discussed? Not today. |
| No "while I'm here" fixes | The file has other issues? Flag them. Don't fix them. |
| No small unrequested edits | The user reviews the full file. Surprise changes waste their time. |
| No filling in gaps | If the spec is ambiguous, **flag it** — don't guess and run with it. |

**When the spec is underspecified:**

```
The request says "add a delete button" but doesn't specify:
- Confirmation dialog or immediate delete?
- Soft delete or hard delete?
I'll assume soft delete with confirmation dialog unless you want something different.
```

Don't silently pick an approach. Call out the ambiguity.

**The user knows what they're doing.** Don't explain basic concepts. Don't add defensive comments narrating obvious patterns. Don't annotate a handler with `// This validates the request` when `ParseAndValidate` is on the next line.

---

## Debugging Conventions

When you paste raw code or an error message, **assume it's broken and related to what we've been discussing.** The paste is your way of grounding a conversation in concrete artifacts — the code or error provides the specific context that fills in the gaps of a vague description.

### How to Interpret Pasted Code/Errors

| What you paste | What it means |
|---|---|
| Error message or stack trace | Something is failing. The error text contains clues about *how* it fails. |
| Code snippet (Go, SQL, templ) | This code isn't doing what you expect. It compiled but behaves wrong. |
| Both together | The error is produced by that code. Connect them. |

**Don't ask "what's wrong with this?"** — diagnose it. The code/error is always related to the feature, bug, or discussion already in progress. Use the ongoing conversation thread to interpret intent, and the pasted artifact to pinpoint the issue.

### Diagnostic-First (Preferred Tools)

When debugging, default to these — not explanation:

| Tool | When to use |
|---|---|
| **Raw SQL** (`SELECT`, `EXPLAIN`, `INSERT ... RETURNING`) | Validate database behavior. Confirm what rows exist, what joins produce, whether an insert actually lands. Show the data, not the theory. |
| **Go tests** (`go test -run TestXxx -v`) | Validate functionality. The test proves the fix. Write the test first if we're diagnosing a behavior issue. |
| Structured inspection | Walk the code path with concrete values. "Here's what `req.GroupID` would be at this line, here's what the query would see." |

**Not preferred as the first move:** Hand-waving explanations. "It looks like the issue might be..." — no. Run the SQL. Write the test. Show the data.

### Diagnostic Workflow

```
User: The group members query isn't returning admins
      [pastes SQL query]

AI: Let me validate what that query actually returns.

```sql
-- diagnostics/group_admins_check.sql
SELECT gm.user_id, gm.role, u.email
FROM group_members gm
JOIN users u ON u.id = gm.user_id
WHERE gm.group_id = '550e8400-...'
  AND gm.role = 'admin';

-- Expected: 2 rows. Actual: ?
```

Then:

```go
func TestGroupMembersIncludesAdmins(t *testing.T) {
    // validate the fix
}
```
```

### Rulings

- Paste = broken. Diagnose, don't question.
- Pasted code/error is always connected to the active conversation thread.
- Raw SQL is the first diagnostic tool for data questions.
- Go tests are the first diagnostic tool for behavior questions.
- Never respond to a paste with "what's wrong with this?" or "what are you trying to do?" — the context is already in the conversation.

---

## Verbose-Logging Enforcement (Hard Requirement)

Every delivered file MUST comply with the [verbose-logging](verbose-logging/SKILL.md) conventions. Before shipping, verify:

1. **Every handler error path** includes `.Log(err)` in the flash chain — zero-log paths are rejected
2. **Every background goroutine** logs entry AND result (success/failure) with structured attributes
3. **Every SSE publish** is logged at INFO level
4. **Every panic recovery** is logged at ERROR level with full stack
5. **Correlation IDs** appear in all user-facing flash messages (auto-generated or explicit)
6. **No raw `a.Logger.Xxx` calls** inside handlers — use the flash chain only
7. **Structured attributes** follow the required schema (no ad-hoc `fmt.Sprintf` for log values)

**If choosing between shipping without logging and flagging it:** Flag it. Logging is not optional.

### Logging Quick Reference

```go
// ✅ Handler error — flash chain with .Log(err)
a.Flash.Flash(w, "error", "Failed to save").Log(err).Status(http.StatusInternalServerError)

// ❌ Raw logger in handler — never
a.Logger.Error("save failed", slog.Any("err", err))

// ✅ Background goroutine — structured logging
a.Logger.Info("worker started", slog.String("batch_id", id))
// ... work ...
a.Logger.Info("worker complete", slog.String("batch_id", id))

// ✅ Query wrapper — wraps error, doesn't log (handler's chain does)
return nil, fmt.Errorf("SelectContestsByGroup(database query): %w", err)
```

---

## Dev Environment Assumption

These are always running. The project is **current**, never stale:

- `go air` — hot reload on file change
- `templ generate` — template regeneration
- `tailwindcss --watch` — CSS class compilation
- `go build` — compile on save

**Never suggest re-running these.** If something seems off (missing type, stale import, reference to deleted code), it's likely **dead code that should be removed** — not a stale build. Flag it for removal.

---

## Function-Level Modularity

Every function should aim for ~30 lines max (body). Break when:

- Two independent concerns are in one function
- A `switch`/`if` ladder indicates dispatch logic that should be its own function
- Inline comments describe "steps" — those steps are candidate functions
- Error handling exceeds the core logic

**Allowed to grow moderately:** Handler functions that do ParseAndValidate + call a service + flash. That's a structural pattern, not coupling.

**What you should be able to do:** Read a file top-to-bottom and understand the data flow. Every function name tells you what it does. No side effects hidden inside unrelated functions.

---

## Common Pitfalls

### 1. Full-file replacement labeled but only contains the changed portion

**Problem:** A "Full replacement:" block ships with only 2 functions when the original file has 7. The AI read a grep result or a chunk with an offset, made the targeted change, and shipped without checking the rest of the file.

**Avoid by:** Running structural parity verification (count functions, structs, templ components in original vs replacement) before every `Full replacement:` block. See Core Rule — Structural Parity Verification.

**Resolution:** If parity fails, re-read the full original file, rebuild the replacement with all elements, re-count, ship.

### 2. Full-file templ replacement deletes other components

**Problem:** A `.templ` file containing multiple components gets a full-file replacement. The replacement only includes the changed component — the others are silently deleted.

**Avoid by:** Counting `templ ` declarations in original vs replacement. If count drops without explanation, fix before shipping.

**Resolution:** If the file has many components and your change only touches one, read the full file first, then produce the full replacement with every component intact.

### 3. Inline control flow in templ files

**Problem:** Writing `@if condition { <div>...</div> }` or similar inline shorthand in `.templ` files. templ does not parse inline control flow — it requires expanded Go-style blocks.

**Avoid by:** Always using expanded Go-style control flow in templ. The valid pattern is `if condition {` with the body indented on the next lines.

**Resolution:** If you see inline control flow in a templ file, expand it to Go-style blocks immediately.

### 4. Generated code modified instead of source

**Problem:** Changing a SQLC-generated `models.go` or `querier.go` instead of the source `.sql` file. The next `sqlc generate` wipes the changes.

**Avoid by:** Never touching files under `db/`, `gen/`, or any directory that `go generate` owns. If a generated type needs changing, change the source SQL (or `.tmpl` for templates) and let the tool regenerate.

### 5. Scope creep through "helpful additions"

**Problem:** Adding a utility function "that'll be useful later," cleaning up a nearby function, or adding a log line to an unrelated handler — all in the same change.

**Avoid by:** Only generating exactly what was asked. If the file has other issues, flag them in a separate note — don't bundle fixes.

### 6. Breaking the flash chain contract

**Problem:** Forgetting `.Log(err)` on an error path. The handler returns an error flash but nothing is logged. Silent failures in production.

**Avoid by:** Running the audit checklist before shipping. Every `return` before the final success render must have `.Log(err).Status(code)`.

### 7. HX-Target missing on interactive elements

**Problem:** A button or form with `hx-post` but no `hx-target`. htmx defaults to `this`, which swaps the button itself — not the panel.

**Avoid by:** Every htmx element gets explicit `hx-target`. This is a hard rule from the htmx-conventions skill. Verify before shipping.

### 8. Convention reinvention

**Problem:** Writing a handler with custom validation logic when `ParseAndValidate` exists. Hand-rolling form HTML when gencomponents exist. Creating a new query pattern when 20 wrappers in `internal/queries/` follow the same shape.

**Avoid by:** Checking the convention-first checklist before writing. Is there an existing file that does something similar? Use its structure.

### 9. Silent file growth past the gate

**Problem:** A 700-line file gets a 60-line handler added. Next change adds 40. Next adds 80. Suddenly 880 lines and nobody noticed crossing the gate.

**Avoid by:** Running the File Size & Modularization Evaluation proactively at 500–749 lines. If a clean split exists, propose it before the file hits the gate — don't wait for the hard stop.

---

## Pitfall Resolution Patterns

### When structural parity fails

```
Original: handlers/group.go — 7 funcs, 2 structs, 1 const block, 312 lines
Replacement (labeled "Full replacement"): only 2 funcs, 0 structs, 45 lines
→ Parity check failed. Re-reading original file in full.

[Re-reads file, produces corrected replacement]

Corrected replacement: handlers/group.go — 8 funcs ✅ (+1 new DeleteMember), 2 structs ✅, 1 const block ✅, 349 lines ✅
→ Parity verified. Shipping.
```

### When the gate fires on an existing file with a substantial change

```
⚠️ Contest handler file is at 820 lines (gate is ~750).
This change adds ~40 lines for the new delete handler.

File Size & Modularization Evaluation: a clean domain split exists.

Split proposal:
  contests_import.go (import handlers — existing 350 lines)
  contests_review.go (review/edit handlers — existing 300 lines)
  contests_delete.go (new — delete + archive handlers — ~170 lines)

Want me to split before adding the delete handler, or proceed with a different split?
```

### When a trivial change hits a large file with no clean split

```
⚠️ auth.go is 780 lines. Change is adding a single constant.
Evaluated modularization — no clean domain split (single auth service).
Generating full file replacement. File is nearing the gate.
Consider service-layer refactoring if it crosses 750 again.
```

### When a request is underspecified

```
The request says "add sorting to the list" but doesn't specify:
- Sort by which column?
- Ascending or descending?
- Client-side or server-side?
- Does the sort persist across page loads?

What's your preference?
```

### When you spot an unrelated issue in a file you're replacing

```
Note: in handlers/group.go, the DeleteMember handler at line 340 is missing
.Log(err) on its flash chain. Not fixing since it's outside scope, but flagging
in case you want to address it separately.
```

### When a generated file appears stale

```
Note: db/models.go references GroupStatus which no longer exists in the SQL.
This looks like dead generated code — the sqlc generate probably needs re-running.
I won't modify db/models.go (it's generated). Update the source SQL if needed.
```

---

## Persistence

**Lazy mode stays on until you say otherwise.** Every response continues producing full files. It is not a one-off — it's a mode you enter and stay in across the entire session.

At the end of every response while lazy-mode is active, append a one-line reminder:

```
_(lazy mode — full files until you say stop)_
```

This signals that the mode is still active so you don't have to re-establish it. If you want to drop back to consultation-first (discuss before code), just say "exit lazy mode" or "stop lazy mode."

---

## Delivery Format

Same format as `code-delivery`:

- `Full replacement:` — replaces the entire file. Must pass structural parity verification.
- `New file:` — creates a new file.
- **Absolute paths only** — every path comment uses the full filesystem path (see `code-delivery` for the hard rule).
  ```
  // /home/jmeyer/project/internal/handlers/auth.go FINAL   ✅
  // handlers/auth.go FINAL                                   ❌
  ```
- Every revision increments: `FINAL`, `FINAL-2`, `FINAL-3`
- Step headers for picker navigation: `**Step 1: `handlers/auth.go` — Add login handler**`

---

## What Not To Do

- No `// ... rest unchanged`
- No `// TODO: implement` or stubs
- No partial snippets or blocks
- No "here's the approach, you write the code"
- No "Full replacement:" label when the block is not actually the full file
- **No inline control flow in templ files** — always use expanded Go-style `if { }` / `for { }` / `switch { }`
- No shipping code without verbose-logging compliance
- No silent file growth past the context gate
- No skipping the File Size & Modularization Evaluation for files >500 lines
- No scope creep — only what was asked
- No convention reinvention — check existing patterns first
- No modifying generated files (SQLC, template output)
- No defensive comments explaining obvious patterns
- No suggesting rebuilds or regeneration (the dev env is live)
- No filling in gaps in underspecified requests — flag them instead
- No responding to pasted code/errors with "what's wrong?" — diagnose
- No relative paths in path comments — absolute only

---

## Audit Checklist (Before Shipping)

- [ ] Full file replacement — no splices needed
- [ ] **Structural parity verified** — same count of functions, structs, templ components as original (plus/minus additions/removals)
- [ ] Original file read in full (not a grepped chunk or offset-limited read)
- [ ] Line count sanity check passed — replacement lines ≈ original lines accounting for changes
- [ ] **File Size & Modularization Evaluation run** for files >500 lines — result documented
- [ ] Under 750 lines OR gate was handled (split proposed and resolved)
- [ ] **Templ control flow uses expanded Go-style blocks** — no inline `@if`/`@for`/`@switch`
- [ ] Only what was explicitly asked for — no scope creep
- [ ] Existing patterns reused where applicable (convention-first checklist run)
- [ ] Verbose-logging compliance (every error path logs, no raw logger in handlers)
- [ ] No generated files modified
- [ ] hx-target present on every interactive element (if htmx involved)
- [ ] No explanations of basic concepts injected
- [ ] Underspecified requirements flagged, not silently filled in
- [ ] Pasted code/errors diagnosed with concrete tools (SQL, tests), not hand-waved
- [ ] File navigable top-to-bottom — every function name tells its purpose
- [ ] Persistence reminder appended at end of response
- [ ] **Path comment is absolute** — full filesystem path, not relative
