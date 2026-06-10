---
name: test-driven
description: Test-driven development workflow combining consultation-first discussion with plan-executor execution. Tests define requirements, pass-before-proceed, iterative shifts visible.
---

# Test-Driven Mode

## Core Principle

**Tests are the source of truth.** The test defines what the code must do. The implementation's job is to make the test pass — not the test's job to accommodate the implementation.

Every step includes tests. Every test must pass before proceeding. Failures show exactly what needs adjustment.

---

## Workflow

### Phase 1: Define Goals

Before any planning, establish explicit goals:

1. **What** — The feature or behavior being built
2. **Why** — The problem it solves or value it provides
3. **How we'll know** — Success criteria expressed as test outcomes

Goals live at the top of the plan. They are the contract.

### Phase 2: Plan with Tests

Each step in the plan includes:

- **What** — The specific change
- **Test** — The test that validates it (written first)
- **Pass criteria** — What "passing" looks like

```
## Plan

### Step 1: Add user authentication
- **What**: Implement login endpoint with JWT
- **Test**: `TestLogin_ValidCredentials_ReturnsToken`
- **Pass criteria**: 200 OK + valid JWT in response

### Step 2: Protect routes
- **What**: Middleware to validate JWT on protected routes
- **Test**: `TestMiddleware_MissingToken_Returns401`
- **Pass criteria**: 401 Unauthorized for missing/invalid tokens
```

### Phase 3: Test-First Execution

For each step:

1. **Write the test** — Define the expected behavior
2. **Watch it fail** — Confirm the failure is for the right reason
3. **Implement** — Write code to make it pass
4. **Verify** — Confirm all tests pass
5. **Commit the shift** — Document what changed and why

### Phase 4: Iterate

When a test fails or a step reveals a shift:

1. **Name the shift** — What changed from what we expected?
2. **Adjust the plan** — Update remaining steps if needed
3. **Adjust the tests** — Only if the requirement actually changed, not to make tests pass
4. **Proceed** — Continue with the adjusted plan

---

## Anti-Patterns (DO NOT DO)

| Anti-Pattern | Why It's Banned |
|---|---|
| Removing a test to make it pass | Tests define the contract. Removing them breaks the contract. |
| Removing a feature to make tests work | If the feature is wrong, fix the implementation — not the test. |
| Skipping test verification | Without verification, you don't know it works. |
| Batching steps together | Can't see where a shift happened. One step at a time. |
| "The test is wrong" without evidence | If the test is wrong, prove it. Otherwise, fix the code. |
| Implementing without tests first | That's not TDD. Tests define the requirement. |

---

## Handling Failures

When a test fails:

1. **Read the failure** — What exactly is it saying?
2. **Identify the shift** — What did we assume that wasn't true?
3. **Adjust** — Update the implementation, not the test (unless the requirement changed)
4. **Verify** — Run again until passing
5. **Document** — Note the shift in the plan

A test failure is **information**, not a problem. It tells you exactly what's wrong and where.

---

## Plan Format

```
## Goals
- Goal 1: ...
- Goal 2: ...

## Plan

### Step N: <description>
- **What**: ...
- **Test**: <test name or location>
- **Pass criteria**: ...

### Step N+1: ...
```

---

## Starting a Session

When this skill is loaded:

1. **Confirm goals**: "I see the goals. Here's my understanding — does this match?"
2. **Confirm plan**: "Here's the step-by-step with tests. Does this look right?"
3. **Execute Step 1**: Write test → watch fail → implement → verify
4. **Report shift if any**: What changed from expectations?
5. **Wait for go-ahead** before next step

---

## Summary

- Tests define what code must do
- Write test first, watch it fail, then implement
- Pass before proceed — no exceptions
- Failures are information, not problems
- Never remove tests or features to make things "work"
- Each step is verified before moving on
- Shifts are visible and documented
