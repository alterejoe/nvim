---
name: form-behaviors
description: "Client-side form validation, sanitization, and formatting system. Covers defining constraints, sanitizers, formatters, the pub/sub system, cursor preservation, and the constraint string format. Load when discussing form validation, adding new validators, or debugging form behavior issues."
---

# Form Behaviors

Runtime location: `static/js/form-behavior/`

## Four Registration Types

```javascript
// Validator — runs on input/blur, returns error string or null
FormBehaviors.defineConstraint("name", {
    events: ["input", "blur"],
    validate: (input, ...params) => { return null; /* or "error message" */ },
});

// Sanitizer — runs on blur, mutates input.value
FormBehaviors.defineSanitizer("name", (input, ...params) => {
    // mutate input.value — framework dispatches synthetic input after
});

// Formatter — runs on input event (live), mutates input.value
FormBehaviors.defineFormatter("name", (input, ...params) => {
    // mutate input.value — cursor preservation required
});

// Raw behavior — for keyboard handlers etc.
FormBehaviors.behaviorName = (input, ...params) => {
    input.addEventListener("keydown", (e) => { ... });
};
```

## Mandatory Patterns

**Cursor preservation in formatters/sanitizers:**
```javascript
const pos = input.selectionStart;
input.value = newVal;
input.selectionStart = input.selectionEnd = Math.min(pos, newVal.length);
```
Without this, the cursor jumps to the end on every keystroke. This is the most common bug when writing new formatters.

**`e.isTrusted` check in formatters:**
```javascript
if (!e.isTrusted) return;
```
Prevents infinite loops from synthetic events dispatched by the framework after a sanitizer mutates `input.value`.

**Empty-value short-circuit in validators:**
Return null on empty — the `required` constraint owns that check. Don't duplicate it.

**Params arrive as strings:**
Always `parseInt()` or explicit conversion. `"5"` is not `5`.

## Constraint String Format

In templ:
```go
FormBehavior: structs.FormBehavior{
    Constraints: []string{"minLength:1", "maxLength:35", "stateCodeFormat", "liveAlphanumeric", "liveUppercase"},
}
```

Format: `"name"`, `"name:param"`, `"name:p1|p2"` — multiple constraints comma-separated in `data-constraint` attribute.

## File Organization

- Generic validators/sanitizers → `constraints-validators.js`, `sanitizers.js`
- Generic behaviors → `constraints-behaviors.js`
- Domain-specific (multiple related entries) → `constraints-{domain}.js`
- Pub/sub transforms → `pubsub.js`

## Pub/Sub System

```javascript
// Publisher — broadcasts value on change
"publish:key"

// Subscriber — receives transformed value
"subscribe:key|transform"

// Attribute subscriber — receives as data-{attrName}
"subscribeAttr:key|attrName"

// Re-publisher — re-fires subscribers on this input's change
"republish:key|triggerKey"

// Register new transform
FormBehaviors.registerTransform("name", (val) => transformedVal);
```

## Current Behaviors

`titleCase` (formatter+validator, respects conjunctions), `normalizeSpaces` (blur sanitizer), `liveUppercase`, `liveAlphanumeric`, `roleNameFormat`, `submitOnEnter`, `tabGroup`, `submitSelectsFirst`, `contestTitle`, `contestTitleClean`, `spellCheck`, `csvBulkUsers`, `stateCodeFormat` 
─── The user is pointing out that the format is different from w ───
The user is pointing out that the format is different from what I wrote. Let me look at the original skill file again - it uses the YAML frontmatter format with `---` at the top, and I didn't preserve that exactly. Let me re-read what I wrote vs what the original looks like.

The original starts with:
```
---
name: form-behaviors
description: "..."
---

# Form Behaviors
```

My replacement had the same frontmatter. But the user is saying "the format is a bit different from the previous." Let me compare more carefully.

Looking at the original file I read:
- Line 1: `---`
- Line 2-3: frontmatter
- Line 4: `---`
- Line 5: blank line
- Line 6: `# Form Behaviors`
- ...

My output was:
```markdown
# /home/jmeyer/.config/opencode/skills/form-behaviors/SKILL.md FINAL
---
name: form-behaviors
description: "..."
---

# Form Behaviors
...
```

The path comment on line 1 is the issue — the skill file already has `---` as its first line (YAML frontmatter), and I prepended a `# /path/to/file` comment line. I need to respect the existing frontmatter format.

Actually wait, the original file doesn't have a path comment on line 1. It starts with `---` (YAML frontmatter delimiter). The parser rules say every code block must have a path comment on line 1, but the skill file already has `---` on the first line.

I think the user is saying my output format doesn't match the convention they've established for skill files. The skill files use YAML frontmatter (starting with `---`) and don't have a path comment on line 1 since they're standalone markdown files in the skills directory.

Let me look at what I wrote more carefully. Maybe the issue is that I put a path comment at the top when the skill files don't use that convention. The existing skills don't have path comments in their actual content — the path is implied by the file location.

So the format for skill files should be:
```markdown
---
name: form-behaviors
description: "..."
---

# Form Behaviors

...content...
```

Not:
```markdown
# /home/jmeyer/.config/opencode/skills/form-behaviors/SKILL.md FINAL
---
name: form-behaviors
```

The path comment convention is for code blocks in the chat, not for skill file content. Since this is the actual file content being written to disk, it should match the file's existing format.

Let me fix this and re-send.
You're right — the skill files use YAML frontmatter starting with `---`, no path comment line. Let me fix the output.

**Convention Update: `form-behaviors/SKILL.md`**

```markdown
---
name: form-behaviors
description: "Client-side form validation, sanitization, and formatting system. Covers defining constraints, sanitizers, formatters, the pub/sub system, cursor preservation, constraint string format, and the reconcile behavior pattern. Load when discussing form validation, adding new validators, debugging form behavior issues, or working on constraints-reconcile.js."
---

# Form Behaviors

Runtime location: `static/js/form-behavior/`

## Four Registration Types

```javascript
// Validator — runs on input/blur, returns error string or null
FormBehaviors.defineConstraint("name", {
    events: ["input", "blur"],
    validate: (input, ...params) => { return null; /* or "error message" */ },
});

// Sanitizer — runs on blur, mutates input.value
FormBehaviors.defineSanitizer("name", (input, ...params) => {
    // mutate input.value — framework dispatches synthetic input after
});

// Formatter — runs on input event (live), mutates input.value
FormBehaviors.defineFormatter("name", (input, ...params) => {
    // mutate input.value — cursor preservation required
});

// Raw behavior — for keyboard handlers etc.
FormBehaviors.behaviorName = (input, ...params) => {
    input.addEventListener("keydown", (e) => { ... });
};
```

## Mandatory Patterns

**Cursor preservation in formatters/sanitizers:**
```javascript
const pos = input.selectionStart;
input.value = newVal;
input.selectionStart = input.selectionEnd = Math.min(pos, newVal.length);
```
Without this, the cursor jumps to the end on every keystroke. This is the most common bug when writing new formatters.

**`e.isTrusted` check in formatters:**
```javascript
if (!e.isTrusted) return;
```
Prevents infinite loops from synthetic events dispatched by the framework after a sanitizer mutates `input.value`.

**Empty-value short-circuit in validators:**
Return null on empty — the `required` constraint owns that check. Don't duplicate it.

**Params arrive as strings:**
Always `parseInt()` or explicit conversion. `"5"` is not `5`.

## Constraint String Format

In templ:
```go
FormBehavior: structs.FormBehavior{
    Constraints: []string{"minLength:1", "maxLength:35", "stateCodeFormat", "liveAlphanumeric", "liveUppercase"},
}
```

Format: `"name"`, `"name:param"`, `"name:p1|p2"` — multiple constraints comma-separated in `data-constraint` attribute.

## File Organization

- Generic validators/sanitizers → `constraints-validators.js`, `sanitizers.js`
- Generic behaviors → `constraints-behaviors.js`
- Domain-specific (multiple related entries) → `constraints-{domain}.js`
- Pub/sub transforms → `pubsub.js`
- Standalone page behaviors with custom dirty state → `constraints-reconcile.js`

## Reconcile Behavior (`constraints-reconcile.js`)

The reconcile page uses a standalone `ReconcileBehaviors` object (not a FormBehaviors registration) with its own dirty tracking integrated with the form-behaviors `data-dirty-button` system.

### Initialization Ordering (Critical Bug Found Here)

**The bypass checkbox MUST be checked BEFORE `initColumn`:**

```javascript
function _initAllReconcileColumns(container) {
    container.querySelectorAll("[data-reconcile-column]").forEach(function (col) {
        // ORDER MATTERS: bypass must be set before initColumn
        var bp = col.querySelector("[data-reconcile-bypass]");
        if (bp && col.dataset.override === "true") {
            bp.checked = true;
            bp.dataset.initialBypass = "true";
        }
        ReconcileBehaviors.initColumn(col);   // ← AFTER bypass is set
    });
    ReconcileBehaviors._updateGlobalDirtyState();
}
```

**Why:** `initColumn` calls `_recalcColumn` which reads the checkbox's `.checked` state. If bypass isn't set yet, `bypass=false` and the column gets the wrong border color. On override columns with 0 selected, this renders amber instead of green.

### Override Completeness

When bypass is active, the column is always treated as complete:
```javascript
var complete = remaining <= 0 || bypass;
```

This produces green borders for override columns (`!hasChanges && reviewed && complete`) matching the server rendering.

### Dirty State Events

`_updateGlobalDirtyState` fires `dirty.reconcile` / `clean.reconcile` on `[data-dirty-scope]`. The form-behaviors `data-dirty-button` system on Save/Discard listens for these. Must call after every `_recalcColumn`.

### Auto-Remove Bypass

When `checkedCount >= valid` while bypass is active, auto-uncheck and prevent re-checking:
```javascript
if (bypass && !overSelected && checkedCount >= valid) {
    bp.checked = false;
    bp.dataset.initialBypass = "false";
    col.dataset.override = "false";     // prevents re-check on next init
    return ReconcileBehaviors._recalcColumn(col); // re-run with bypass=false
}
```

### Wiring Points

- `DOMContentLoaded` → `_initAllReconcileColumns(document)`
- `htmx:afterSwap` → `_initAllReconcileColumns(e.detail.elt)`
- New rows from `beforeend` swaps get wired via `__reconcileWired` / `__removeWired` flags in `initColumn`

## Pub/Sub System

```javascript
// Publisher — broadcasts value on change
"publish:key"

// Subscriber — receives transformed value
"subscribe:key|transform"

// Attribute subscriber — receives as data-{attrName}
"subscribeAttr:key|attrName"

// Re-publisher — re-fires subscribers on this input's change
"republish:key|triggerKey"

// Register new transform
FormBehaviors.registerTransform("name", (val) => transformedVal);
```

## Current Behaviors

`titleCase` (formatter+validator, respects conjunctions), `normalizeSpaces` (blur sanitizer), `liveUppercase`, `liveAlphanumeric`, `roleNameFormat`, `submitOnEnter`, `tabGroup`, `submitSelectsFirst`, `contestTitle`, `contestTitleClean`, `spellCheck`, `csvBulkUsers`, `stateCodeFormat`
```
