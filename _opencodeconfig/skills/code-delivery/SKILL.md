---
name: code-delivery
description: Code output format preferences — full-function vs partial, full-file thresholds, delivery labels, absolute path enforcement, and block context rules. Load when asking for code to set delivery expectations.
---

# Code Delivery Preferences

This skill overrides the generic delivery rules in `consultation-first` with hard preferences. When loaded, follow these rules exactly — no asking for clarification.

## Core Rule

**No diffs, no partial snippets, no descriptions of what to change.** Every code block is a complete, drop-in replacement — either a full file or a full function/struct/block.

## Full-File Threshold

When touching an existing file, read the entire file first. Then:

| File size | Behavior |
|---|---|
| ≤ 500 lines | Always deliver the full file |
| > 500 lines | Run File Size & Modularization Evaluation first. Then either modularize, deliver the full file, or use line-numbered block delivery. |
| (carve-out) | If the change is trivial (delete a function, add a simple function), block delivery is fine regardless of size — but still run the evaluation and include line numbers. |

For **new files**: always deliver the full file.

## File Size & Modularization Evaluation

### Principle

**Full file replacement is the default and the goal.** Small modular files make this always possible. Before falling back to partial or block delivery, evaluate whether the file should be split into smaller atomic files such that future changes can always be full replacements.

### Decision Flow

Every change to an existing file runs this evaluation:

```
Change request → read file
 │
 ├─ New file → Full file delivery ✓
 │
 └─ Existing file:
      │
      ├─ ≤500 lines → Full file replacement ✓
      │
      └─ >500 lines:
           │
           ├─ Can the file be split at domain boundaries
           │  into files ≤500 lines each?
           │  │
           │  ├─ YES → Propose the split. Make the change
           │  │        in the resulting smaller files using
           │  │        full replacements going forward.
           │  │
           │  └─ NO → Is the change small/trivial?
           │         │
           │         ├─ YES → Block delivery WITH LINE NUMBERS
           │         │        (file.go:start-end in path comment)
           │         │        ⚠️ Note file size + modularization
           │         │           eval result so user knows.
           │         │
           │         └─ NO/substantial → Full file replacement.
           │              ⚠️ Note: "File is N lines — consider
           │                 modularizing if it keeps growing."
```

### What "Modularization" Means

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

Each resulting file must be coherent, readable top-to-bottom, and ≤500 lines.

### If Modularization Is Blocked

If the file is genuinely single-responsibility and can't be domain-split, still flag it:

```
⚠️ auth.go is 620 lines. No clean domain split exists — it's a single
authentication service. Delivering as line-numbered block.
Consider refactoring if it keeps growing.
```

## Block Delivery (function/struct/interface) — Line Number Mandate

When delivering a single block because full-file replacement isn't possible or appropriate after evaluation:

1. **Line numbers are MANDATORY** in the path comment — `file.go:42` or `file.go:42-58`
   - `// /home/jmeyer/project/internal/handlers/auth.go:142-158 FINAL`
   - Without them, the user must search for the insertion point → wasted back-and-forth
2. The block is the **complete function/method/struct/interface** — signature, body, closing brace. No `// ... rest unchanged`.
3. Include the **package declaration and imports** if the block references types from them.
4. Include a **signature comment** if the function isn't trivially identifiable: `// Block: func (s *Service) CreateUser(...)`.
5. Never omit the return statement or error handling "for brevity."

## Templ Control Flow — Expanded Only (Hard Rule)

**templ files must NEVER use inline control flow.** templ does not parse inline `@if`, `@for`, `@switch` shorthands. All control flow must use expanded Go-style block syntax:

```
✅ Valid — expanded Go-style:
  if err != nil {
    <div>Error</div>
  }

  for _, item := range items {
    <li>{ item.Name }</li>
  }

  if val := getSomething(); val != nil {
    <p>{ val }</p>
  }

❌ Invalid — inline control flow (templ does not parse these):
  @if err != nil { <div>Error</div> }
  @for _, item { <li>...</li> }
```

**Always use `{` on the same line as the control flow keyword, with the body indented below.** The pattern `if val := expr; condition {` is the correct Go/templ syntax.

## Delivery Labels

Every code block MUST be preceded by exactly one of these labels on its own line:

- `Full replacement:` — the entire file, replacing what's there
- `New file:` — a brand new file being created
- `Block: \`func X\`` — a single function/block replacement (name the symbol)
- `Block: \`struct X\`` — a single struct replacement
- `Addition:` — appending to an existing file (avoid if possible; prefer full file)

## Absolute Paths (Hard Rule)

**Every path comment MUST use an absolute path.** Never relative. The user copies the file into their project — the path tells them exactly where it goes.

```
// /home/jmeyer/project/internal/handlers/auth.go FINAL           ✅ absolute
// /home/jmeyer/project/cmd/server/main.go FINAL                   ✅ absolute
// /home/jmeyer/project/templates/pages/group.templ FINAL          ✅ absolute

// handlers/auth.go FINAL                                           ❌ relative
// ../internal/models/user.go FINAL                                 ❌ relative
// ./cmd/main.go FINAL                                              ❌ relative
```

The path reflects the **actual filesystem location** in the user's project, not the workspace root. Derive it from the file's real location as seen by `read` or `grep` results — those tools return absolute paths.

## FINAL Markers

Always append `FINAL` (or `FINAL-N` for revisions) to the path comment. The path comment format follows AGENTS.md rules:

```
// /home/jmeyer/project/internal/handlers/auth.go FINAL
// /home/jmeyer/project/internal/handlers/auth.go FINAL-2
```

First version of a block = `FINAL`. Each revision within the same response increments: `FINAL`, `FINAL-2`, `FINAL-3`, etc.

## What Not To Do

- No `// ... rest unchanged`
- No `// TODO: implement`
- No inline comments describing what *would* go in a blank body
- No "here's the approach, you write the code"
- No partial snippets that require the user to splice them in
- **No blocks or partials without line numbers** — always include `file.go:start-end` in the path comment
- **No inline control flow in templ files** — always use expanded Go-style `if { }` / `for { }` / `switch { }`
- No asking "do you want the full file?" when the thresholds above already answer it
- No relative paths in path comments — absolute only
- No skipping the modularization evaluation — run it every time before fallback to partial delivery
- No proposing a split for a file ≤500 lines without a clear reason

## When This Skill Should Be Loaded

- When asking for new code
- When asking for revisions to existing code
- When you're tired of getting diffs or partial snippets
- Before `/plan-executor` sessions
```
