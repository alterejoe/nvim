---
name: htmx-conventions
description: "Complete htmx UX conventions covering the ephemeral swap contract, form-behaviors edit path, POST→poll→restore async pattern, save/discard/continue navigation model, and common pitfalls encountered in the portal codebase."
---

# HTMX Conventions

Build consistent, maintainable, interactive UI using htmx and templ. This skill covers the full interaction model — from simple form edits to async background operations with progress tracking.

---

## The Contract

htmx swaps are **ephemeral**. They modify the DOM, not the database. This is the single most important rule.

| Action | What happens |
|---|---|
| htmx swap (toggle, edit, add, remove) | DOM only. Nothing is persisted. |
| **Save** POST | Persists to the database. Re-renders the panel client-side — no navigation, same page. |
| **Discard** or page refresh | Loads from server state. All unsaved htmx swaps are discarded. That's correct. |
| **Continue** | Navigation button. Only enabled when save state is clean (all reviewed or in a ticket). |

**Form-behaviors** tracks dirty inputs client-side and controls Save button enabled/disabled. Server renders the authoritative state on every full page load.

---

## Hard Rules

### 1. hx-target is REQUIRED

Every htmx attribute on every interactive element MUST include `hx-target`. No exceptions. No relying on implicit default behavior:

```templ
// ✅ Correct
@gencomponents.Button(&structs.Button{
    Hx: structs.Hx{
        Method: structs.POST,
        URL:    "/path/to/handler",
        Target: "#target-panel",
        Swap:   "innerHTML",
    },
    Type: "button",
})

// ❌ Wrong — omitted hx-target defaults to "this"
Hx: structs.Hx{
    Method: structs.POST,
    URL:    "/path/to/handler",
    Swap:   "innerHTML",
}
```

### 2. innerHTML is the Default Swap

Use `innerHTML` unless you have a specific reason for a different swap type. When proposing an alternative, explain why `innerHTML` won't work.

| Swap | When to use |
|---|---|
| `innerHTML` | Default. Replaces content inside the target element. |
| `outerHTML` | Replacing the target element itself. Use when you need to change the wrapper's attributes or id. |
| `beforeend` | Appending new elements (e.g., confirm dialogs injected into a skeleton container, file upload entries). |
| `none` | Side-effect-only actions with no DOM change (e.g., triggering server work that produces no visible result). |

### 3. Same Component for Initial Render and Post-Async Restoration

A panel that's swapped out (e.g., replaced by a progress bar) must be restorable by rendering the exact same templ component:

```templ
// ✅ Correct: single component used for both
templ ElectionStatusList(batchID string, counties []db.Row) { ... }

// Initial page load uses it, and the progress completion returns it.
```

### 4. Gencomponents for Interactive Elements

Use gencomponents for all buttons, forms, inputs with `hx-*`, `data-constraint`, `data-keymap-*`, or `data-format` attributes. See the **gencomponents** skill for available variants.

- Convert: `<button>`, `<form>`, `<input>`, `<select>`, `<textarea>` with any interactive attribute
- Leave raw: layout `<div>`, static text, `<span>`, wrapper containers, hidden inputs

Raw `<button>` elements are only acceptable when no gencomponent variant exists for the specific styling/behavior needed. This is rare.

### 5. Never SSE Unless Polling Can't Work

Default to the POST→poll→restore pattern for async operations. SSE adds complexity with the event stream connection, reconnection logic, and race conditions with htmx swaps. Only use SSE when:

- Real-time upload/migration progress that genuinely can't be polled
- The user explicitly approves SSE after you've explained the alternative

If SSE is used, see the **sse-pattern** skill for the r3labs/sse/v2 + htmx-ext-sse setup.

**Never add polling on top of SSE.** They race — the poll can wipe SSE-inserted content.

---

## The Two Interaction Models

Every interactive page uses one of these two approaches. **Pick one per page. Never use both.**

### Poll-Driven (Default for Async)

Self-contained polling component that owns its lifecycle:

```templ
templ ProgressPoller(batchID string, done, total int) {
    <div id="poll-widget"
         hx-get={ fmt.Sprintf("/path/%s/progress", batchID) }
         hx-trigger="every 1s"
         hx-target="#poll-widget"
         hx-swap="innerHTML">
        @ProgressContent(done, total)
    </div>
}
```

- Component has its own `id` — matches `hx-target`
- `hx-trigger="every Ns"` controls poll interval
- `hx-target="#self-id"` — targets itself
- `hx-swap="innerHTML"` — content replaces itself
- **No OOB attributes** — keep inline, simple
- Poll stops naturally when the component is replaced by one without `hx-trigger`

Good for: progress tracking, state convergence after mutations, picking up admin-side changes.

### Event-Driven (HX-Trigger)

Custom events for immediate reactions to specific actions:

```
HX-Trigger: {"event-name": {"optional-data": "value"}}
```

Listen with `hx-trigger="event-name from:body"` or `hx-trigger="event-name from:#target"`.

Good for: ticket submission triggering a page-wide refresh, OOB footer updates after a specific mutation.

**Common path for event-driven:** OOB swaps for footer state after an entity toggle. The toggle handler returns the swapped entity (via `hx-target`) plus an OOB footer update. This is acceptable when a toggle needs to immediately update page-level state (e.g., "all reviewed" status, continue button). Don't use this for every mutation — only when the OOB update is genuinely needed.

---

## Form-Behaviors for Edits (Default Path)

This is the standard way to handle edit pages. Individual inputs don't POST on change. Instead, they use the **form-behaviors** system:

- `data-constraint` attributes for client-side validation rules
- `data-sanitize` for input cleaning
- `data-format` for display formatting
- Dirty state is tracked client-side by form-behaviors
- Dirty state enables/disables the Save button

The Save button POSTs the entire form. The handler validates, persists, and re-renders the panel — no navigation. The Discard button reloads the page from server state.

```templ
@gencomponents.Form(&structs.Form{
    Common: structs.Common{ID: "my-form"},
    Hx: structs.Hx{
        Method: structs.POST,
        URL:    "/path/to/save",
        Target: "#content-panel",
        Swap:   "innerHTML",
    },
}) {
    @gencomponents.Input(&structs.Input{
        Common: structs.Common{
            Name:        "field_name",
            Value:       entity.FieldValue,
        },
        FormBehavior: structs.FormBehavior{
            Constraints: "required|min:2",
            Dirty:       true,
        },
    })
    @gencomponents.Button(&structs.Button{
        Common: structs.Common{
            ID:    "save-btn",
            Value: "Save",
        },
        FormBehavior: structs.FormBehavior{
            DirtyScope: "#my-form",
        },
        Type: "submit",
    })
    @gencomponents.Button(&structs.Button{
        Common: structs.Common{
            ID:    "discard-btn",
            Value: "Discard",
        },
        Type: "reset",
    })
}
```

### When to POST Individual Entities

Individual entity POSTs (a mutation that immediately hits the server and returns a swapped row) are the **exception**, not the rule. Use them only when:

1. **The mutation has an immediate server-side side effect** beyond just marking dirty — creating/updating a proofing record, resolving a ticket, queueing background work.
2. **The handler needs to return an OOB update** (e.g., footer state refresh) that can't wait for a poll cycle.
3. **The user explicitly requests it** because the interaction needs to feel instantaneous.

Normal toggles, adds, removes — use form-behaviors dirty state + Save POST.

---

## POST → Poll → Restore (Async Operations)

The full lifecycle for any background operation with a visible progress phase.

### Lifecycle

```
┌──────────────────────────────────────────────────────────────────────┐
│  1. User clicks action button (e.g., Promote, Process, Import)      │
│     → hx-post triggers handler                                      │
│     → Handler starts goroutine (context.WithTimeout, 10min max)     │
│     → Handler returns polling component                             │
│     → Polling component replaces #target-panel via innerHTML        │
├──────────────────────────────────────────────────────────────────────┤
│  2. Polling component self-polls every 1s                           │
│     → Handler reads goroutine result or queries DB                  │
│     → Poll returns progress content (no wrapper id)                 │
├──────────────────────────────────────────────────────────────────────┤
│  3. Goroutine completes                                             │
│     → Next poll call detects completion                             │
│     → Handler fetches fresh data from DB                            │
│     → Handler returns RESTORED PANEL COMPONENT                      │
│     → Panel has no hx-trigger → poll stops naturally                │
│                                                                     │
│  (Optionally: confirmation dialog opened via beforeend into         │
│   a skeleton container before the POST fires)                       │
└──────────────────────────────────────────────────────────────────────┘
```

### Confirmation Dialog Before POST

For destructive actions, open a gencomponents `SMDestructiveConfirmDialog` via `hx-get` / `beforeend`. The confirm button in the dialog POSTs to the actual handler:

**Step 1 — Promote button in the panel:**
```templ
@gencomponents.UniqueButton(&structs.Button{
    Common: structs.Common{
        ID:    "action-btn",
        Value: "Promote",
    },
    Hx: structs.Hx{
        Method: structs.GET,
        URL:    fmt.Sprintf("/path/%s/promote/confirm", batchID),
        Target: "#skeleton",
        Swap:   "beforeend",
    },
    Type: "button",
})
```

**Step 2 — Confirm dialog handler:**
```go
gencomponents.SMDestructiveConfirmDialog(&structs.DestructiveConfirmDialog{
    Title:         "Promote Imports",
    Message:       "This will promote all imports to official data...",
    ConfirmPhrase: "PROMOTE",
    ConfirmLabel:  "Promote",
    Hx: structs.Hx{
        Method: structs.POST,
        URL:    fmt.Sprintf("/path/%s/promote", batchID),
        Target: "#target-panel",
        Swap:   "innerHTML",
    },
}).Render(r.Context(), w)
```

**Step 3 — POST handler starts goroutine and returns polling component:**
```go
setProgress(batchIDStr, "running")
go runPromote(a, batchIDStr)

gencomponents.ConfirmDialogClose().Render(r.Context(), w)
templates.ProgressPoller(batchIDStr, 0, 1).Render(r.Context(), w)
```

The `ConfirmDialogClose()` is an OOB component that removes the dialog from the DOM. The `ProgressPoller` replaces the target panel.

### Required Components

#### Polling Component (wrapper)

Must have `id`, `hx-get`, `hx-trigger`, `hx-target=#self`, `hx-swap=innerHTML`:

```templ
templ ProgressPoller(batchID string, clearingDone, clearingTotal, promotingDone, promotingTotal int) {
    <div id="promote-progress"
         class="p-4"
         hx-get={ fmt.Sprintf("/admin/state/elections/%s/import/promote/progress", batchID) }
         hx-trigger="every 1s"
         hx-target="#promote-progress"
         hx-swap="innerHTML">
        @ProgressContent(clearingDone, clearingTotal, promotingDone, promotingTotal)
    </div>
}
```

#### Progress Content (poll returns this while running)

**No wrapper `id`** — avoids ID nesting when swapped via innerHTML into the polling component:

```templ
templ ProgressContent(clearingDone, clearingTotal, promotingDone, promotingTotal int) {
    <h3 class="text-lg font-bold mb-3">Processing...</h3>
    <div class="mb-3">
        <div class="flex justify-between text-sm mb-1">
            <span>Stage 1: Clearing</span>
            <span>{ fmt.Sprintf("%d / %d", clearingDone, clearingTotal) }</span>
        </div>
        <div class="w-full bg-slate-200 rounded-full h-3">
            <div class="bg-blue-500 rounded-full h-3 transition-all duration-500"
                 style={ fmt.Sprintf("width: %d%%", pct(clearingDone, clearingTotal)) }></div>
        </div>
    </div>
    <div class="mb-3">
        <div class="flex justify-between text-sm mb-1">
            <span>Stage 2: Processing</span>
            <span>{ fmt.Sprintf("%d / %d", promotingDone, promotingTotal) }</span>
        </div>
        <div class="w-full bg-slate-200 rounded-full h-3">
            <div class="bg-green-500 rounded-full h-3 transition-all duration-500"
                 style={ fmt.Sprintf("width: %d%%", pct(promotingDone, promotingTotal)) }></div>
        </div>
    </div>
}
```

#### Error Component

```templ
templ ProgressError(errMsg string) {
    <div class="text-center py-8">
        <div class="text-red-600 text-lg font-bold mb-1">Failed</div>
        <div class="text-gray-500 text-sm mb-2">{ errMsg }</div>
    </div>
}
```

#### Restored Panel Component

Must produce **identical** HTML to the panel that was originally in that position. This is the same component used for the initial page load:

```templ
templ TargetPanel(batchID string, counties []db.Row) {
    // Same structure as the initial page's #target-panel content
    // Gencomponents for all buttons
    // hx-target on every htmx element
}
```

### Async Goroutine Pattern

```go
func runWork(a *app.App, batchIDStr string, pgBatchID pgtype.UUID) {
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
    defer cancel()

    a.Logger.Info("work: goroutine started",
        slog.String("batch_id", batchIDStr),
    )

    err := a.WithTx(ctx, app.RLSSystem, func(q *db.Queries) error {
        total := countItems(ctx, q)
        for i, item := range items {
            if err := doWork(ctx, item, q); err != nil {
                return fmt.Errorf("failed at %s: %w", item, err)
            }
            setProgress(batchIDStr, "running", i+1, total)
            a.Logger.Debug("work: progress",
                slog.String("batch_id", batchIDStr),
                slog.Int("done", i+1),
                slog.Int("total", total),
            )
        }
        return nil
    })

    if err != nil {
        a.Logger.Error("work: failed",
            slog.String("batch_id", batchIDStr),
            slog.Any("error", err),
        )
        setProgress(batchIDStr, "error", 0, 0)
        return
    }

    setProgress(batchIDStr, "complete", 1, 1)
    a.Logger.Info("work: complete",
        slog.String("batch_id", batchIDStr),
    )
}
```

### Progress Poll Handler

```go
func GetProgress(a *app.App) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "text/html")
        batchIDStr := chi.URLParam(r, "batchID")
        status := getProgress(batchIDStr)

        // Complete or no status → render restored panel (poll stops naturally)
        if status == nil || status.Stage == "complete" {
            counties, err := fetchCounties(r.Context(), batchID, q)
            if err != nil {
                templates.ProgressError(err.Error()).Render(r.Context(), w)
                return
            }
            templates.TargetPanel(batchIDStr, counties).Render(r.Context(), w)
            return
        }

        if status.Stage == "error" {
            templates.ProgressError(status.Error).Render(r.Context(), w)
            return
        }

        // In progress
        templates.ProgressContent(status.Done, status.Total).Render(r.Context(), w)
    }
}
```

---

## Save / Discard / Continue Navigation Model

Every review/edit page has these three actions:

**Save:** POSTs the form, persists to DB, re-renders the panel via hx-target innerHTML. No page navigation. After save, the page state is clean — form-behaviors dirty flag clears, Continue button enables.

**Discard:** Reloads the page from server state. Equivalent to a hard refresh — all unsaved htmx swaps are discarded. Implemented as a button that does `window.location.reload()` or an hx-get that re-renders the full page.

**Continue:** Navigation to the next page. **Disabled when the page is dirty.** Enabled only when save state is clean — either all entities are reviewed/have tickets, or the user just saved.

```templ
<div class="flex gap-2">
    @gencomponents.AttentionButton(&structs.Button{
        Common: structs.Common{
            ID:    "discard-btn",
            Value: "Discard",
        },
        // Simple JS reload — discards all unsaved state
        Hx: structs.Hx{
            Method: structs.GET,
            URL:    "/current/page",
            Target: "#content-panel",
            Swap:   "innerHTML",
        },
        Type: "button",
    })
    if !props.IsDirty {
        @gencomponents.PrimaryButton(&structs.Button{
            Common: structs.Common{
                ID:    "continue-btn",
                Value: "Continue",
            },
            Hx: structs.Hx{
                Method: structs.GET,
                URL:    props.ContinueURL,
                Target: "#skeleton",
                Swap:   "innerHTML",
            },
            Type: "button",
        })
    }
</div>
```

---

## Common Pitfalls (From Real Bugs)

### 1. Poll continues forever after completion

**Problem:** The polling component's `hx-trigger="every 1s"` keeps firing even after the async work finishes. The handler keeps re-rendering the same content.

**Fix:** On completion, return a component that does NOT have the polling trigger. The restored panel has no `hx-trigger` attribute → htmx stops polling. This happens naturally when you return a different component (the panel, not the poller).

### 2. Nested ID conflicts when polling

**Problem:** Progress content has an `id` that matches the polling wrapper's `hx-target`. When `innerHTML` replaces the content, you get nested elements with the same ID.

**Fix:** The progress content should have **no wrapper `id`**. Only the polling wrapper has the id. The content is just bare markup swapped into it.

```templ
// ✅ Correct: wrapper has id, content has no id
<div id="poll-widget" hx-target="#poll-widget" ...>
    @ProgressContent(done, total)
</div>

templ ProgressContent(done, total int) {
    // No id attribute here
    <h3>Working...</h3>
    ...
}
```

### 3. Panel components are not identical on initial load vs post-async restore

**Problem:** The original page uses gencomponents buttons with specific IDs. The post-async restore uses different markup (raw buttons, different classes). The result is a visual mismatch.

**Fix:** Use the exact same templ component for both paths. The component that renders `#target-panel` on initial page load must be the same one returned by the progress handler on completion.

### 4. Full-file templ replacements delete existing components

**Problem:** Replacing an entire `.templ` file that contains multiple components. If the replacement doesn't include all the existing components, they're silently deleted.

**Fix:** Never do full-file replacements of `.templ` files. Only append new components or replace individual blocks. If a full-file replacement is necessary, verify every existing component is preserved.

### 5. Confirm dialog hx-target points to wrong container

**Problem:** The confirm dialog's `hx-target` and the action handler's response don't target the same container. The dialog opens correctly, but the POST response (progress bar) goes to the wrong place.

**Fix:** The dialog's submit POST targets `#target-panel` with `innerHTML` — this is the panel being replaced by the progress bar. The dialog itself is injected into `#skeleton` via `beforeend`. The POST handler returns the progress bar (targets `#target-panel`) plus `ConfirmDialogClose()` which OOB-removes the dialog.

### 6. SSE page gets a polling trigger added

**Problem:** An SSE-driven page (file upload) has `every 30s` polling added for "state convergence." The poll reloads the page content, which wipes SSE-inserted upload entries.

**Fix:** Never add polling to SSE-driven pages. Choose one model per page. SSE-driven pages use SSE events for updates; poll-driven pages use polling. Never both.

---

## End-to-End Checklist

Before shipping any htmx interaction, verify:

- [ ] Route exists and maps to a chi handler
- [ ] Handler follows **handler-pattern** conventions (ParseAndValidate, WithTx, flash chain, usererr)
- [ ] Response is a templ partial, not a full page render
- [ ] `hx-target` ID exists in the response HTML — every interactive element has explicit hx-target
- [ ] Swap strategy is `innerHTML` unless explicitly justified otherwise
- [ ] Interactive elements use gencomponents — no raw `<button>` without justification
- [ ] Form-behaviors applied for form inputs (data-constraint, data-sanitize, data-format)
- [ ] Save POSTs without navigating — persists and re-renders in-place
- [ ] Discard reloads from server — reverts all unsaved changes
- [ ] Continue is disabled while dirty — only enabled when save state is clean
- [ ] Async operations use POST→poll→restore — polling component has id + hx-trigger + hx-target=self
- [ ] Progress content has no wrapper id
- [ ] Completion returns the same panel component used for initial load
- [ ] Flash messages wired through the flash chain with `.Log(err)` on error paths
- [ ] Error responses use `usererr`, not raw strings
- [ ] SSE not used unless polling genuinely can't work
- [ ] If SSE is used, no polling is added alongside it
- [ ] Verbose logging follows **verbose-logging** skill conventions (correlation IDs, structured attrs)
- [ ] Edits use form-behaviors dirty state by default — individual entity POSTs are exceptional
