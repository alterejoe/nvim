---
name: sse-pattern
description: "Server-Sent Events implementation in a Go/htmx/templ stack using r3labs/sse/v2 and htmx-ext-sse. Covers setup, patterns (append, get/OOB, dynamic target), race condition pitfalls, the async processor pattern, and common mistakes that took significant debugging time to resolve. Load when discussing SSE, real-time updates, event streaming, publish/subscribe, or diagnosing dropped events."
---

# SSE Pattern — Server-Sent Events

## Stack
- Server: `r3labs/sse/v2` (Go)
- Client: `htmx-ext-sse` 2.2.4 + htmx 2.0.4
- Components: gencomponents (`SSEGetTarget`, `SSEAppendTarget`, `GetSSE`, `AppendSSE`)
- Helpers: `portal-shared/create` (`CreateSSE`, `StartHeartbeat`, `PublishEventSafe`)

## Core Rules — Never Break These

1. **Never publish an empty event.** `r3labs/sse/v2` closes the subscriber channel when `Data` and `Comment` are both empty. Always use `PublishEventSafe`. This single bug caused an entire feature (filing paper upload — 50 pages) to only display 1 of 50 results. Debugging took hours because the connection silently closed with no error.

2. **Never put `sse-swap` and `hx-swap` on the same element that owns `sse-connect`.** Causes recursive re-registration and call stack overflow in the browser.

3. **`sse-connect` goes on `<body>` once, in the layout.** Stable parent that survives navigations. Never on individual components.

4. **`AutoStream=true, AutoReplay=false`** — streams created/cleaned up automatically, no replay storms on reconnect.

5. **Always run `StartHeartbeat`** (20s interval) to prevent proxy idle-close (`ERR_INCOMPLETE_CHUNKED_ENCODING`).

## PublishEventSafe — The Guard

```go
func PublishEventSafe(s *sse.Server, stream, eventName string, data []byte) {
    if len(data) == 0 {
        data = []byte(" ")  // single space prevents connection close
    }
    s.Publish(stream, &sse.Event{
        Event: []byte(eventName),
        Data:  data,
    })
}
```

This function exists because of a production bug. Always use it. Never call `s.Publish` directly.

## Setup

```go
// In main.go or app initialization
sseSrv := create.CreateSSE()
go create.StartHeartbeat(ctx, sseSrv, 20*time.Second)

// SSE endpoint in router
r.Get("/events", func(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "text/event-stream")
    w.Header().Set("Cache-Control", "no-cache")
    w.Header().Set("Connection", "keep-alive")
    w.Header().Set("X-Accel-Buffering", "no")  // required behind nginx
    sseSrv.ServeHTTP(w, r)
})

// Body layout
templ MyBody(groupID string) {
    <body hx-ext="sse" sse-connect={ "/events?stream=my-feature-" + groupID }>
        { children... }
    </body>
}
```

## The Race Condition Problem

This is the hardest lesson learned in this project. When processing files synchronously in a request handler and publishing SSE events as each completes:

**The problem:** The handler renders pending rows, then processes files sequentially, publishing SSE events after each. But the SSE connection is established by the browser AFTER the POST response completes. So events published during the synchronous processing are lost — the browser hasn't connected to the event stream yet.

**Symptoms:**
- First upload works, subsequent ones in a batch don't update
- SSE events fire on the server but never arrive at the client
- Adding `time.Sleep` before publishing "fixes" it sometimes (red flag — timing-dependent)

**The solution — async processor pattern:**
1. Handler receives upload → stores in S3 → inserts DB record → returns pending row immediately
2. Background service/goroutine picks up the work asynchronously
3. When processing completes, the service calls back to publish SSE events
4. By the time the callback fires, the browser has already established the SSE connection

```go
// Handler — return immediately, process async
go func(s3Key, filename string) {
    ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    defer cancel()
    if err := callProcessor(ctx, s3Key, batchID, filename); err != nil {
        logger.Error("processor failed", "filename", filename, "error", err)
    }
}(s3Key, pf.filename)
```

**The retry pattern for the callback handler:**
When the processor calls back, the DB record might not be committed yet (race between the goroutine and the original handler's transaction). Use a linear retry:

```go
var row db.SelectImportRow
var found bool
for i := 0; i < 4; i++ {
    if i > 0 {
        time.Sleep(time.Duration(50*i) * time.Millisecond)
    }
    txErr := a.WithTx(ctx, app.RLSUser, func(q *db.Queries) error {
        var err error
        row, err = queries.SelectImportByKey(ctx, key, q)
        return err
    })
    if txErr == nil {
        found = true
        break
    }
    if !errors.Is(txErr, pgx.ErrNoRows) {
        break  // real error, don't retry
    }
}
// Max wait: 300ms (0 + 50 + 100 + 150)
```

## Three Patterns

### Pattern A — Append (direct HTML push)
SSE event data IS the HTML to append. Simple list, server controls the HTML.

```templ
@gencomponents.SSEAppendTarget(&gencomponents.SSEAppendTargetProps{
    ID:      "my-list",
    Event:   "my-feature-row",
    Default: "Nothing here yet.",
    Class:   "flex flex-col gap-2",
})
```

### Pattern B — Get/OOB (server-driven multi-target)
One event updates multiple elements. Event triggers an hx-get, handler returns OOB fragments.

```templ
@gencomponents.SSEGetTarget(&gencomponents.SSEGetTargetProps{
    ID:         "my-status",
    Event:      "my-feature-updated",
    GetURL:     "/my-feature/status",
    Default:    "0 items",
    LoadOnInit: true,  // also fires on page load
})
```

### Pattern B2 — Get/OOB with dynamic target
Target ID depends on event payload. Use `Vals` with `event.detail.data`.

```templ
@gencomponents.GetSSE(&structs.SSEChannel{
    Event:  "my-feature-row",
    GetURL: "/my-feature/row-status",
    Vals:   "js:{item_id: event.detail.data}",
})
```

## Module Organization

```
internal/sse/myfeature.go     — event name constants + publish helpers
ui/html/myfeature/sse.templ   — OOB fragment components (handlers only)
ui/html/myfeature/page.templ  — uses SSEGetTarget/SSEAppendTarget
```

## OOB Fragment Rules

1. OOB components live in `sse.templ` — never in `page.templ`
2. Always have `hx-swap-oob="true"` or `hx-swap-oob="beforeend:#selector"`
3. Used by handlers only — never rendered on the page directly
4. **Wrap `<details>`, `<tr>`, `<table>`, `<li>` in `<div hx-swap-oob="...">`** — browsers strip semantic elements as top-level OOB fragments

## Common Mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Empty event data | Connection closes silently | `PublishEventSafe` |
| `sse-swap` + `hx-swap` on connect element | Call stack overflow | Separate connect from swap |
| Missing heartbeat | `ERR_INCOMPLETE_CHUNKED_ENCODING` after 30-60s | `StartHeartbeat(ctx, srv, 20s)` |
| `AutoReplay=true` | Replay storm on reconnect | `AutoReplay=false` |
| Publishing during synchronous request | Events lost — browser not connected yet | Async processor pattern |
| OOB `<details>` as top-level fragment | Element stripped by browser | Wrap in `<div>` |
| Missing `X-Accel-Buffering: no` | Events buffered behind nginx | Add header |
| Checking DB before processor commits | `ErrNoRows` on valid record | Linear retry with sleep |
