---
name: verbose-logging
description: "Verbose structured logging conventions using slog with correlation IDs linking flash messages to searchable log entries. Covers log level signals (INFO=working, WARN=warning, ERROR=erroring), the correlation ID pattern, structured attribute schema for aggregators, and integration with handlers, queries, background jobs, and SSE. Replaces the error-handling skill — load for all logging, error handling, flash messages, or debugging discussions."
---

# Verbose Logging

Every log line is a signal. Three signal types map directly to log levels:

| Signal | Level | Meaning | Example |
|--------|-------|---------|---------|
| Data working correctly | `INFO` | Expected path, nominal state | "User 123 created contest 456" |
| Data warning | `WARN` | Unexpected but recoverable | "Retry 2/4: record not yet committed" |
| Data erroring | `ERROR` | Failure, data may be wrong | "Failed to upload file to S3" |

Verbose means: log enough that you can replay a session from logs alone. Every handler entry/exit, every DB write, every external call, every significant branch.

## Logger Setup

Uses `log/slog` (Go stdlib) with two modes:

**Development** — `devslog` (human-readable, color, caller info):
```go
func CreateLogger() *slog.Logger {
    slogOpts := &slog.HandlerOptions{
        AddSource: true,
        Level:     slog.LevelDebug,  // DEBUG+ in dev
    }
    opts := &devslog.Options{
        HandlerOptions:    slogOpts,
        MaxSlicePrintSize: 10,
        SortKeys:          true,
        NewLineAfterLog:   true,
        StringerFormatter: true,
        NoColor:           true,
    }
    return slog.New(devslog.NewHandler(os.Stdout, opts))
}
```

**Production** — JSON handler (aggregator-friendly):
```go
func CreateProductionLogger() *slog.Logger {
    return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
        AddSource: true,
        Level:     slog.LevelInfo,   // INFO+ in prod (no DEBUG)
    }))
}
```

The `interfaces.Logger` in portal-shared wraps this:
```go
type Logger interface {
    Debug(string, ...any)
    Info(string, ...any)
    Warn(string, ...any)
    Error(string, ...any)
}
```

**All code accesses the logger through `app.Logger` — never create ad-hoc loggers.**

## Correlation IDs — Linking Flash to Logs

Every user-facing flash message MUST include a correlation ID that maps directly to a log entry. This is the contract:

**The customer says "Ref: abc-def" → you grep the logs → you see the full chain.**

### How It Works

```
Handler generates correlation ID → prepended to flash message → logged as structured attribute
```

The correlation ID is a URL-safe, short, random string (e.g. 8-char hex or base62). It appears:

1. **In the flash message**: `a.Flash.Flash(w, "error", "Failed to save. Ref: a3f8c2e1")`
2. **In the log line**: `{..., "correlation_id": "a3f8c2e1", "caller": "handlers/xxx.go:42", ...}`
3. **Optionally in the admin UI**: searchable log view

### Flash Chain with Correlation ID

Extend the flash chain to accept/auto-generate a correlation ID:

```go
// Pattern A — auto-generate (simplest, preferred)
a.Flash.Flash(w, "error", "Failed to save contest").Log(err).Status(http.StatusInternalServerError)
// Flash auto-generates cid, appends "Ref: a3f8c2e1" to the message, logs with cid

// Pattern B — explicit (when you have one from the request context)
a.Flash.Flash(w, "error", "Failed to save contest").CorrelationID(cid).Log(err).Status(http.StatusInternalServerError)
```

**Auto-generation rules:**
- Generate a random 8-char hex string → `fmt.Sprintf("%08x", rand.Uint32())`
- Append `" Ref: " + cid` to the message shown to the user
- Log with `slog.String("correlation_id", cid)`
- Store in flash state so retries/success messages in same request share the ID

### What the User Sees

The flash message in the browser includes the ref:
```
"Failed to save contest. Ref: a3f8c2e1"
```

The user emails support: "I got error a3f8c2e1"
Support searches logs → finds exactly the handler, the error, the stack trace, the DB query context.

## Required Structured Attributes

Every log line MUST include these attributes for aggregator consumption (e.g. Loki, Datadog, CloudWatch, Grafana):

| Attribute | Type | Required | Source | Example |
|-----------|------|----------|--------|---------|
| `correlation_id` | string | Yes (flash/error) | Flash chain, handler | `"a3f8c2e1"` |
| `request_id` | string | Yes (HTTP) | Middleware | `"req-abc123"` |
| `caller` | string | Always | `runtime.Caller` | `"handlers/xxx.go:42"` |
| `service` | string | Always | App startup config | `"clientserver"` |
| `environment` | string | Always | App startup config | `"production"` |
| `user_id` | string | When available | Session | `"550e8400-..."` |
| `duration_ms` | int | Performance-sensitive | Manual timing | `342` |
| `err` | error | When applicable | Error value | `"pq: unique violation"` |
| `stack` | string | ERROR level | `debug.Stack()` | Full trace |

**Attach service+environment at logger creation time:**

```go
// In server main.go
logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
    AddSource: true,
    Level:     slog.LevelInfo,
}).With(
    slog.String("service", "clientserver"),
    slog.String("environment", os.Getenv("APP_ENV")),
))
```

**Attach request_id at middleware time:**

```go
func RequestIDMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        id := r.Header.Get("X-Request-ID")
        if id == "" {
            id = fmt.Sprintf("req-%08x", rand.Uint32())
        }
        ctx := context.WithValue(r.Context(), ctxKeyRequestID, id)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}
```

## Integration Points

### 1. Handlers — The Flash Chain (carried over from error-handling skill)

```go
a.Flash.Flash(w, "category", "message").Log(err).Status(http.StatusXxx)
```

**Mandatory rules:**
- Every error path MUST include `.Log(err)` — no silent errors
- `.Log(err)` is the ONLY logging mechanism inside handlers — never `a.Logger.Error(...)` directly
- DB failures always use `usererr.UserMessage(err)` for the user message
- Validation failures use hardcoded strings

**The `.Log()` method produces two log lines:**
1. `ERROR <user message>` with `caller`, `correlation_id`, `err`, `stack`
2. Full goroutine stack trace for deep traceability

**Categories:** `"error"`, `"success"`, `"warning"`, `"info"`

### 2. Query Wrappers — Error Wrapping

Every query wrapper logs its operation on error. The query-pattern conventions apply:

```go
func SelectContestsFromGroupID(ctx context.Context, id pgtype.UUID, q *db.Queries) ([]db.SelectContestsFromGroupIDRow, error) {
    rows, err := q.SelectContestsFromGroupID(ctx, id)
    if err != nil {
        return nil, fmt.Errorf("SelectContestsFromGroupID(database query): %w", err)
    }
    return rows, nil
}
```

The wrapper wraps errors (doesn't log) — the handler's flash chain does the logging. This keeps one log line per error rather than two (wrapper + handler).

**Exception — wrappers that run outside a handler context (background jobs, migrations, etc.):**
```go
func AssertGroupExists(ctx context.Context, id pgtype.UUID, q *db.Queries, logger *slog.Logger) error {
    _, err := q.SelectGroupByID(ctx, id)
    if err != nil {
        logger.Error("Group not found",
            slog.String("group_id", id.Bytes.String()),
            slog.Any("err", err),
        )
        return fmt.Errorf("AssertGroupExists: group %s not found: %w", id.Bytes, err)
    }
    return nil
}
```

### 3. Background Jobs — Goroutine Logging

Goroutines cannot use the flash chain. They MUST use `a.Logger` directly with structured attributes:

```go
go func(s3Key, filename, correlationID string) {
    ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    defer cancel()

    logger.Info("Starting background processor",
        slog.String("correlation_id", correlationID),
        slog.String("filename", filename),
        slog.String("s3_key", s3Key),
    )

    if err := callProcessor(ctx, s3Key, batchID, filename); err != nil {
        logger.Error("Processor failed",
            slog.String("correlation_id", correlationID),
            slog.String("filename", filename),
            slog.Any("err", err),
        )
        return
    }

    logger.Info("Processor completed successfully",
        slog.String("correlation_id", correlationID),
        slog.String("filename", filename),
    )
}(s3Key, pf.filename, correlationID)
```

**Rules:**
- Always capture the correlation_id from the request context before spawning
- Log entry AND exit (or success AND failure) — so you know the job ran
- Include enough context to identify the record (filename, batch_id, record_id)

### 4. SSE Publishing

SSE publishes fire outside the request-response cycle. Log every publish:

```go
func PublishUpdateEvent(sseSrv *sse.Server, stream, eventName string, data []byte, logger *slog.Logger) {
    logger.Info("Publishing SSE event",
        slog.String("stream", stream),
        slog.String("event", eventName),
        slog.Int("data_bytes", len(data)),
    )
    create.PublishEventSafe(sseSrv, stream, eventName, data)
}
```

### 5. Panic Recovery — Log to Die

The panic recovery middleware logs the full stack and re-sets headers:

```go
func (app *App) RecoverPanic(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        defer func() {
            if err := recover(); err != nil {
                w.Header().Set("Connection", "close")
                trace := debug.Stack()
                app.Logger.Error("recovered panic",
                    slog.String("error", fmt.Sprintf("%v", err)),
                    slog.String("trace", string(trace)),
                )
                http.Error(w, fmt.Sprintf("%s", err), http.StatusInternalServerError)
            }
        }()
        next.ServeHTTP(w, r)
    })
}
```

**Rule:** Always log panics at ERROR level with full stack trace. Never silently swallow.

## Admin Log Access (Concept)

Correlation IDs only help if you can search logs by them. The convention is:

1. **Local dev:** `grep a3f8c2e1 /var/log/app/*.json` or `journalctl | grep a3f8c2e1`
2. **Production:** Log aggregator search (Loki, CloudWatch Logs Insights, Datadog Logs) query: `{service="clientserver"} |= "a3f8c2e1"`
3. **Admin UI (future):** Log viewer page at `/admin/logs?correlation_id=a3f8c2e1` that queries the aggregator API

For now, ensure every log line JSON is written to stdout (container stderr) where the aggregator picks it up automatically. The correlation ID + structured attributes make searching trivial.

## usererr — User-Friendly Error Messages

(carried over from error-handling skill verbatim — this section is unchanged)

Location: `github.com/Glass6444/portal-shared/helpers/usererr`

`usererr.UserMessage(err)` converts internal errors into user-safe messages. It interprets in order:
1. Custom registered interpreters
2. pgx/pgconn SQLSTATE codes (full table — see error-handling skill)
3. UUID parse errors → "Invalid ID format"
4. Casbin errors → "You do not have permission"
5. Generic fallback → "An unexpected error occurred"

```go
// main.go — call once before serving
usererr.RegisterDefaultInterpreters()
```

## Logging Audit Rule

Before shipping any change, verify:

1. **Every handler error path** includes `.Log(err)` — zero-log paths are rejected
2. **Every background goroutine** logs entry AND result (success/failure)
3. **Every SSE publish** is logged at INFO level
4. **Every panic recovery** is logged at ERROR level with stack
5. **Correlation IDs** appear in all user-facing flash messages
6. **No raw `a.Logger.Xxx` calls** inside handlers — use the flash chain only
7. **Structured attributes** follow the required schema (no ad-hoc string formatting)
