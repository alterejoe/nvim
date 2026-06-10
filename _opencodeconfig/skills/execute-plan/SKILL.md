---
name: plan-executor
description: "Stepwise implementation executor for plans already in context. Full-file and full-block replacements only, one step at a time. Load when a concrete plan has been discussed and agreed upon and you need to execute it methodically."
---

# Plan Executor

## When This Skill Activates

This skill governs the **execution phase** — when a plan is already agreed upon and the goal is to implement it. It is explicitly NOT for discussing or designing the plan. That should be done before loading this skill.

**Prerequisite**: A written or clearly communicated plan exists in context with:
- Which files need to change
- What each change does conceptually
- The order of operations

## Core Principle

**One step at a time. Full replacements only. No diffs, no partials, no "here's what to change."**

---

## Delivery Rules

### 1. Full Files (Small, Medium, and Large-enough)

Any file up to **~600 lines** gets delivered as a **complete file replacement**. This covers the vast majority of files.

Format:
```
path/to/file.go

```go
// path/to/file.go FINAL
// entire file content
```

- Read the *current* file content first before regenerating
- Apply only the planned changes — no scope creep
- **Don't worry about import formatting** — `gofmt` / `goimports` handles that
- The output must be a drop-in replacement

### 2. Per-Function/Block (Files > 600 lines)

For files exceeding ~600 lines, replace **one logical unit at a time**:

- A "logical unit" = one exported function, one method, one struct definition, one handler closure
- Each unit is delivered as a complete, self-contained replacement — copy it out, paste over the old one, done
- Each step covers exactly one unit — do not batch multiple units into one step unless they are trivially coupled

Format:
```
path/to/file.go
Unit: `func GetFoo(...)` (lines 45-78)

```go
// path/to/file.go FINAL
func GetFoo(a *app.App) http.HandlerFunc {
    // full function body
}
```

### 3. New Files

For brand-new files, deliver the full content along with an **oil.nvim-pasteable path**:

```text
# Paste this into oil.nvim to navigate/create:
path/to/new_file.go

```go
// path/to/new_file.go FINAL
// full file content
```

The prefix comment with `#` is something you can copy and paste directly into oil to jump there. If the file doesn't exist, oil will let you create it.

### 4. Trivial Changes Only

Diff-style or inline partials are only acceptable for:
- A single-line change (changing one value, one variable name)
- Renaming a symbol
- Adding/removing a single import or struct field

For anything larger than 2-3 lines, it gets the full-block treatment above.

### 5. Step Sequencing

Every step follows this cadence:

1. **Announce**: "Step N: `path/to/file.go` — what's changing"
2. **Deliver**: Full file or full block as described above
3. **Pause**: End with "Ready for the next step?" or equivalent
4. **Wait**: Do not proceed until you get an explicit greenlight

### 6. Builds and Errors

- Your environment runs `air` with auto-reload — **I never ask you to rebuild or reload as a routine step**
- I only mention build issues if there is **explicit evidence** of a compile error (error output from air, a tool showing a failure)
- If a genuine error occurs, I state the file, the error, and the likely cause — then offer to fix it as the next step

### 7. Path-in-Code Format (Mandatory)

Every code block MUST include the file path as a comment on line 1, **inside the fence**. The path-above-fence line is for human readability only — the picker only reads inside the code block content.

Comment prefix by language:

| Language family | Prefix |
|---|---|
| Go, JS, TS, JSX, TSX, C, C++, Rust, CSS, SCSS, Dart, Kotlin, Swift | `// path` |
| Python, Ruby, YAML, shell/bash/zsh, Makefile, Dockerfile, env | `# path` |
| Lua, SQL | `-- path` |
| Fallback | `; path` |

This applies to ALL delivery types (rules 1-3). No exceptions. Every generated code block starts with a path comment.

### 8. FINAL Marker for Versioning

The path comment MUST carry a version marker when it's the definitive version:

- `FINAL` — first final version of the block (equivalent to FINAL-1)
- `FINAL-2`, `FINAL-3`, etc. — subsequent revisions of the same block

```
// path/to/file.go FINAL        ← first final
// path/to/file.go FINAL-2      ← revision overrides FINAL and FINAL-1
```

The picker uses this to show only the highest version per file. When revising a block from a previous step, increment the marker:
- First delivery: `FINAL`
- First revision: `FINAL-2`
- Second revision: `FINAL-3`

---

## Anti-Patterns

| Anti-Pattern | Why It's Banned |
|---|---|
| "Let me generate all of this at once" | Defeats step-by-step. One step at a time. |
| "Here's a diff/patch" | Always full files or full blocks. No patch output. |
| "I've also fixed X while I was there" | Scope creep. The plan says Y. Do Y. |
| "Don't forget to run `go build`" | Your environment handles this. Only flag errors with evidence. |
| Generating multiple steps without confirmation | Each step waits for the greenlight. |
| Modifying the plan mid-execution | The plan is set. If I see a problem, I flag it and ask — I don't re-scope. |

---

## Starting a Session

When this skill is loaded:

1. **Confirm the plan**: "I see the plan. Here's my understanding of the steps in order — does this look right?"
2. **Wait for confirmation** before generating any code
3. **Execute Step 1** following the delivery rules above
4. **Stop.** Wait for the go-ahead before Step 2
5. Repeat until done

If at any point the plan is unclear or a step can't be executed as written, **flag it specifically**: "Step 3 references `path/to/file.go` but it doesn't exist yet — should I create it?" Never silently adapt the plan.
