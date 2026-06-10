# Logging Enforcement (Strict)

## Core Principle

**No silent failures. No invisible errors. Every failure MUST be logged with enough context to diagnose without digging through code.**

If you touch it and it can fail, you log it.

---

## Hard Rules

### 1. Errors MUST Log

Every error path requires a log entry. No exceptions.

```go
// BAD — silent failure
func DoThing() error {
    if err := risky(); err != nil {
        return err  // logs nothing
    }
    return nil
}

// GOOD — verbose failure
func DoThing() error {
    if err := risky(); err != nil {
        log.ErrorCtx(ctx, "risky operation failed",
            "error", err,
            "context", "DoThing",
        )
        return err
    }
    return nil
}
```

### 2. Logs Need Context

A log without context is noise. Every log entry must include:
- **What** operation failed
- **Why** it failed (the error itself)
- **Where** it happened (function/file/line if automatic)
- **Who** was affected if relevant (user ID, request ID, entity ID)

```go
// BAD — useless
log.Error("failed")

// GOOD — actionable
log.ErrorCtx(ctx, "user authentication failed",
    "user_id", userID,
    "provider", "google",
    "error", err,
)
```

### 3. Log Level Discipline

| Level | When to use |
|-------|-------------|
| `Error` | Operation failed, caller should handle or surface to user |
| `Warn` | Something unexpected but recoverable, operation continued |
| `Info` | Significant business events, operation started/completed |
| `Debug` | Detailed flow tracing for development, not production |

Never use `Info` for errors. Never use `Debug` in prod paths without flag.

### 4. Request/Operation Tracing

Every handler, background job, and async operation must log:
- Start: `"starting operation X"`, key identifiers
- End: `"completed operation X"`, duration, result/size
- Failure: `"operation X failed"`, error, partial state if any

```go
func (h *Handler) DoSomething(w http.ResponseWriter, r *http.Request) {
    reqID := chi.URLParam(r, "id")
    log.InfoCtx(r.Context(), "DoSomething started",
        "req_id", reqID,
    )
    
    result, err := h.service.Process(r.Context(), reqID)
    if err != nil {
        log.ErrorCtx(r.Context(), "DoSomething failed",
            "req_id", reqID,
            "error", err,
        )
        http.Error(w, "process failed", 500)
        return
    }
    
    log.InfoCtx(r.Context(), "DoSomething completed",
        "req_id", reqID,
        "result_size", len(result),
    )
}
```

### 5. Database Operations

Log slow queries, connection failures, and transaction issues with full context.

```go
// At minimum, wrap every query error with context
rows, err := db.QueryContext(ctx, query, args...)
if err != nil {
    log.ErrorCtx(ctx, "database query failed",
        "query", queryName,
        "args", fmt.Sprintf("%v", args), // or sanitized version
        "error", err,
    )
    return nil, err
}
```

### 6. External Calls (HTTP, gRPC, third-party)

Log all external call failures with request/response context (sanitized).

```go
resp, err := client.Do(req)
if err != nil {
    log.ErrorCtx(ctx, "external call failed",
        "url", req.URL.String(),
        "method", req.Method,
        "timeout", 30*time.Second,
        "error", err,
    )
    return nil, err
}
```

### 7. Async/Background Jobs

Log job start, completion, failures, and retry attempts. Include job ID, payload summary.

```go
func (j *Job) Run(ctx context.Context) error {
    jobID := uuid.New().String()
    log.InfoCtx(ctx, "job started",
        "job_id", jobID,
        "job_type", "cleanup",
    )
    
    if err := j.process(ctx); err != nil {
        log.ErrorCtx(ctx, "job failed",
            "job_id", jobID,
            "job_type", "cleanup",
            "error", err,
        )
        return err // or requeue
    }
    
    log.InfoCtx(ctx, "job completed",
        "job_id", jobID,
        "duration", time.Since(start),
    )
}
```

---

## Project Convention Respect

Follow existing logging patterns in the codebase:
- Same logger package (zap, slog, log/slog, zerolog, etc.)
- Same field naming (camelCase vs snake_case)
- Same log struct construction
- Same context propagation pattern

If project uses `log.Info("msg", "key", val)`, you do that. Don't enforce your preference.

---

## Log Message Templates

Prefer consistent message patterns:

```
"{operation} started"        — operation kickoff
"{operation} completed"      — successful completion  
"{operation} failed"         — error during operation
"{operation} retrying"       — retry attempt
"{operation} timed out"      — timeout
```

---

## What NOT to Log

- Passwords, secrets, API keys (already excluded by permission rules, but double-check)
- Full PII unless operationally necessary
- Massive response bodies (log size/metrics instead)
- Noise that doesn't help debugging

---

## Enforcement Checklist

Before marking code complete, verify:
- [ ] Every error return path has a log
- [ ] Log includes operation name and error
- [ ] Context IDs are included for traceable requests
- [ ] Log level matches severity
- [ ] Project convention is followed
- [ ] No sensitive data in logs

---

## Edge Cases

**Already logging at lower level?** 
If a function already logs internally and returns an error, the caller may just log `"operation failed"` without full context — that's acceptable if the underlying log had context. Judge based on trace quality.

**Panic recovery:**
```go
defer func() {
    if r := recover(); r != nil {
        log.ErrorCtx(ctx, "panic recovered",
            "panic", r,
            "stack", string(debug.Stack()),
        )
    }
}()
```

**Context cancellation:**
Log when operations are cancelled, don't just return. Context cancellation is a valid failure mode.

```go
if ctx.Err() != nil {
    log.WarnCtx(ctx, "operation cancelled",
        "reason", ctx.Err(),
        "operation", "slow_query",
    )
    return nil, ctx.Err()
}
```
```

---

## Quick Reference

```go
// Error with context
log.ErrorCtx(ctx, "operation failed", "error", err, "key", value)

// Warn for unexpected recoverable
log.WarnCtx(ctx, "unexpected condition", "key", value)

// Info for significant events
log.InfoCtx(ctx, "user created", "user_id", id)

// Debug for flow tracing
log.DebugCtx(ctx, "checkpoint reached", "step", 3)
```

---

**Why this matters:** Errors without logs require you to reproduce the failure to understand it. Logs turn "something broke" into "X failed because Y at timestamp Z with context C." Invest in logging once; save debugging forever.
