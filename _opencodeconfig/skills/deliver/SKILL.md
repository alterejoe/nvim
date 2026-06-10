---
name: deliver
description: Collects and redisplays full-file code blocks from the most recent job in code-delivery format. Strips discussion, thinking, and partial blocks — just the files, ready to copy. Companion to lazy-mode.
---

# Deliver

**Load this skill when:** You've been discussing changes in lazy-mode, multiple files have been generated across several responses, and now you want all the files collected in one place — clean, copyable, nothing else.

This is a companion to `lazy-mode`. Lazy-mode produces full files. Deliver collects them.

---

## Core Rule — Files Only, Nothing Else

When invoked, search the current session for code blocks with `Full replacement:` or `New file:` labels from the **most recent job only**. Redisplay them in code-delivery format. Strip everything else — no discussion, no thinking output, no partial snippets, no "note:" blocks.

**The output is purely:**
- Code blocks with `// path/to/file.go FINAL` headers
- Each preceded by its delivery label (`Full replacement:` or `New file:`)
- Grouped logically (all files for feature X together)
- Ordered chronologically within the job
- **Only from the most recent job** — not accumulated session history

---

## What to Collect

| Include | Exclude |
|---|---|
| `Full replacement:` blocks (most recent job only) | Discussion text |
| `New file:` blocks (most recent job only) | Thinking/reasoning output |
| Path comments with FINAL markers | Partial snippets |
| | Block deliveries (function-only, struct-only) |
| | "Note:" or "⚠️" flags |
| | Error messages, logs, diagnostic output |
| | Files from previous jobs in the same session |

---

## Job Scoping — Most Recent Work Only

### What Is a "Job"

A **job** is the most recent logical unit of work — the last feature, fix, or batch of coordinated changes. It represents everything the user was just working on.

### How to Detect Job Boundaries

Scan backward from the last message in the session. Collect all matching blocks until you encounter a **job boundary**:

1. **A previous `deliver` invocation** — files before it were already collected and delivered
2. **A clear topic switch** — the user explicitly introduced a new feature/subject without referencing previous files
3. **A sustained gap in code generation** — 10+ consecutive messages without a `Full replacement:` or `New file:` block

### Detection Strategy

```
Start from the last message in the session.
Work backward.
Collect every `Full replacement:` and `New file:` block.
Stop when you hit any of these:
  - Another `deliver` invocation (those files were already shown)
  - A user message introducing a new topic that doesn't reference
    any of the files you've collected so far
  - 10+ consecutive messages with zero code blocks
```

### Rationale

The user works on one thing at a time. Showing files from 3 features ago wastes attention. If they want to collect everything at the end of the session, they can invoke `deliver` progressively after each job.

---

## Output Format

Each file gets a clean, standalone presentation:

```
**Step N: `path/to/file.go` — [brief description]**

Full replacement:
```go
// path/to/file.go FINAL
[code]
```
```

Use step numbering to group related files. Add a one-line description pulled from the original conversation context.

---

## Detection Rules

To find the right blocks in the session:

1. **Scan for delivery labels** — `Full replacement:` and `New file:` on their own lines
2. **Scope to the most recent job** — apply job boundary detection (see Job Scoping)
3. **Grab the code block** immediately following each label
4. **Verify FINAL marker** — skip blocks without `FINAL` in the path comment (non-FINAL = provisional, not ready to deliver)
5. **Deduplicate** — if the same file has FINAL and FINAL-2, only show FINAL-2 (highest version)
6. **Ignore prose between blocks** — the user wants files, not the conversation

---

## When to Load

- After a long lazy-mode session with files scattered across multiple responses
- Right before copying changes into the project
- When the user says "deliver" or "collect the files" or "show me what we've got"

---

## Example

**Before (scattered across conversation with multiple jobs):**

```
Job 1 (messages 1-10): auth.go, group.go
Job 2 (messages 11-20): contest.go, main.go   ← most recent
```

**After `deliver` is invoked:**

```
**Step 1: `handlers/contest.go` — Add contest CRUD**

Full replacement:
```go
// handlers/contest.go FINAL
[complete file]
```

**Step 2: `cmd/server/main.go` — Register contest routes**

Full replacement:
```go
// cmd/server/main.go FINAL
[complete file]
```

(No auth.go or group.go — those were from a previous job.)
```

---

## What Not To Do

- Don't re-explain the changes — the files speak for themselves
- Don't add context or commentary — the user was in the conversation, they know
- Don't show provisional blocks (no FINAL marker)
- Don't show multiple versions of the same file — only the highest FINAL-N
- **Don't include files from previous jobs** — only the most recent work unit
- Don't include blocks from other conversations — session-scoped only
```

---

Three complete files ready to save. The key additions across all three:

| Skill | What was added |
|---|---|
| `code-delivery` | New **Templ Control Flow — Expanded Only** section + "No inline control flow in templ files" in What Not To Do |
| `lazy-mode` | New **Common Pitfall #3: Inline control flow in templ files** + "No inline control flow in templ files" in What Not To Do + audit checklist item |
| `deliver` | No templ-specific changes needed (deliver is a collector, not a generator) |
