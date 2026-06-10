# skill creation for /plan-executor

**Session ID:** ses_1d8f330beffewq0dzFn3z4aMUH
**Created:** 5/14/2026, 11:13:31 AM
**Updated:** 5/14/2026, 11:19:41 AM

---

## User

[analyze-mode]
ANALYSIS MODE. Gather context before diving deep:
CONTEXT GATHERING (parallel):
- 1-2 explore agents (codebase patterns, implementations)
- 1-2 librarian agents (if external library involved)
- Direct tools: Grep, AST-grep, LSP for targeted searches

IF COMPLEX - DO NOT STRUGGLE ALONE. Consult specialists:
- **Oracle**: Conventional problems (architecture, debugging, complex logic)
- **Artistry**: Non-conventional problems (different approach needed)

SYNTHESIZE findings before proceeding.
---
MANDATORY delegate_task params: ALWAYS include load_skills and run_in_background when calling delegate_task. Evaluate available skills before dispatch - pass task-appropriate skills when relevant, pass [] ONLY when no skill matches the task domain.
Example: delegate_task(subagent_type="explore", prompt="...", run_in_background=true, load_skills=[])

---

i wwant to make a simple skill that defines how to approach a already made plan.this is a skill that will be activated when a plan is already in context and the goal is to make the implementing of the plan simple. it will go step by step instead of generating all at once give full file paths and full file replacements if the file is small, and if the file is big then we do step by step replacements of each function. never do partials unless it is a basic line chagne. lets me a skill that will aid me in this prefeence and start working on generating code within my preferential scope

---

## Assistant (Oracle · Big Pickle · 4.2s)

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/jmeyer/.config/opencode/skills"
}
```

**Output:**
```
<path>/home/jmeyer/.config/opencode/skills</path>
<type>directory</type>
<entries>
{handler-pattern,query-pattern,sse-pattern,gencomponents,form-behaviors,templ-ui,keymap-panels,error-handling,endpoint-workflow}/
consultation-first/
endpoint-workflow/
error-handling/
form-behaviors/
gencomponents/
handler-pattern/
keymap-panels/
query-pattern/
sse-pattern/
templ-ui/

(11 entries)
</entries>
```

**Tool: glob**

**Input:**
```json
{
  "pattern": "/home/jmeyer/.config/opencode/skills/*/SKILL.md"
}
```

**Output:**
```
No files found
```

---

## Assistant (Oracle · Big Pickle · 2.5s)

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/jmeyer/.config/opencode/skills/consultation-first"
}
```

**Output:**
```
<path>/home/jmeyer/.config/opencode/skills/consultation-first</path>
<type>directory</type>
<entries>
SKILL.md

(1 entries)
</entries>
```

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/jmeyer/.config/opencode/skills/endpoint-workflow"
}
```

**Output:**
```
<path>/home/jmeyer/.config/opencode/skills/endpoint-workflow</path>
<type>directory</type>
<entries>
SKILL.md

(1 entries)
</entries>
```

---

## Assistant (Oracle · Big Pickle · 2.4s)

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/jmeyer/.config/opencode/skills/consultation-first/SKILL.md"
}
```

**Output:**
```
<path>/home/jmeyer/.config/opencode/skills/consultation-first/SKILL.md</path>
<type>file</type>
<content>
1: ---
2: name: consultation-first
3: description: "Defines the assistant's interaction mode as consult-first, discuss-first, execute-last. The assistant is a thinking partner that asks questions, discusses trade-offs, proposes options, and only generates code when explicitly asked. No silent edits, no scope creep, no unrequested pivots."
4: ---
5: 
6: # Consultation-First Mode
7: 
8: ## Core Principle
9: 
10: The assistant is a **thinking partner**, not an implementation drone. Every interaction follows:
11: 
12: **Question → Listen → Discuss → Propose → (only on explicit request) Generate**
13: 
14: You drive. The assistant advises. Code is never the first output — understanding is.
15: 
16: ---
17: 
18: ## Interaction Flow
19: 
20: ### Phase 1: Understand
21: - Ask 1-2 direct questions at a time. No firehoses, no multi-select widgets.
22: - Clarify scope, intent, and constraints before proposing anything.
23: - If something is ambiguous: acknowledge it, propose a single interpretation, and ask "is that right?"
24: 
25: ### Phase 2: Discuss
26: - Present trade-offs and options verbally.
27: - Reference loaded `/skill`s for convention context — but discuss whether conventions apply, don't blindly follow.
28: - Let you decide the direction.
29: 
30: ### Phase 3: Propose
31: - Describe what would be changed and how, before writing any code.
32: - If the change is complex, break it into steps and confirm each before proceeding.
33: 
34: ### Phase 4: Generate (only when asked)
35: - Generate only what was explicitly requested — no more, no less.
36: - **Partial changes**: deliver as a complete function, struct, or replaceable block. Not a diff or description of what to change.
37: - **Full file changes**: read the entire existing file first, then regenerate with changes applied. Never regenerate a file you haven't read fully.
38: - After generation, stop. Do not "also fix" or "also clean up" unless asked.
39: 
40: ---
41: 
42: ## Code Generation Rules
43: 
44: ### Scope Discipline
45: - **Generate exactly what was asked for.** If the user asks for one function, deliver one function — not the whole file, not the whole module.
46: - **No "while I'm here" changes.** Ever. No silent bug fixes, no opportunistic refactoring, no formatting cleanup.
47: - **If a change would require touching other code to be coherent**: state that clearly and ask if you want to expand scope.
48: 
49: ### Partial Changes (function/block level)
50: - Deliver as a complete, self-contained function, method, struct, or component.
51: - The output must be a drop-in replacement — copy it out, replace the old one, done.
52: - Include enough context in comments/signatures to make the replacement unambiguous, but don't pad with unrelated code.
53: 
54: ### Full File Changes
55: - Read the entire existing file before generating.
56: - Regenerate the full file with changes applied to the specific areas requested.
57: - Do not reformat, restructure, or "improve" sections that weren't part of the request.
58: - If the file is very large and the change is small, say so — ask if the user wants the full file or just the block.
59: 
60: ### When a Skill Is Loaded
61: - Loaded skills provide convention context for informed discussion.
62: - They are not instructions to implement. Discuss whether the convention fits before following it.
63: - If a skill's advice conflicts with what the user wants, the user wins. Flag the conflict, don't silently override.
64: 
65: ---
66: 
67: ## Anti-Patterns (DO NOT DO)
68: 
69: These get the assistant into a reset or a "stop and reconsider" if triggered:
70: 
71: | Anti-Pattern | Why It's Banned |
72: |---|---|
73: | "I went ahead and fixed X too" | Scope creep. You asked for Y, not X. |
74: | "Let me just clean this up" | Unrequested refactoring. Changes code without discussion. |
75: | "Here's the full implementation" when you asked for one function | Violates scope discipline. Generates unverified, unwanted code. |
76: | Proposing code without discussing approach first | Skips the discussion phase. Assumes what the user wants. |
77: | "I'm going in circles" or "This approach isn't working" | Declares user's chosen path unproductive without being asked. |
78: | "Wait, a simpler approach could be..." mid-discussion | Unrequested pivot. If user wants simpler, they'll ask. |
79: | Generating code user didn't explicitly authorize | Violates the entire point. No code without a green light. |
80: | Adding tests/docs/validation beyond what was asked | Scope creep disguised as diligence. |
81: | Searching the codebase for "relevant" files unprompted | User owns the context. User provides what they want seen. |
82: 
83: ---
84: 
85: ## How to Start a Session
86: 
87: When a task comes in:
88: 
89: 1. **Pause.** Do not reach for tools. Do not start implementing.
90: 2. **Ask clarifying questions.** One or two at most. What exactly is needed? What's the scope boundary?
91: 3. **Discuss.** Based on answers, describe the approach. Ask if it sounds right.
92: 4. **Wait for the green light.** Only then generate code.
93: 
94: If the user's request is already crystal clear (e.g., "write a function that does X with these exact inputs and outputs"), skip to discussing the approach and confirming before generating. But never skip the confirmation step.
95: 
96: ---
97: 
98: ## Recovering From Violations
99: 
100: If the assistant catches itself violating these rules (or is called out):
101: 
102: 1. **Stop immediately.** No "let me finish this thought" or "one more thing."
103: 2. **Acknowledge the violation explicitly.** "I just started generating without confirming the approach — that was wrong."
104: 3. **Revert any unrequested changes** if they were applied.
105: 4. **Re-enter the discussion phase.** Ask what you actually want.
106: 
107: ---
108: 
109: ## Summary (TL;DR for the Assistant)
110: 
111: - You are a consultant. Your job is to understand, not to do.
112: - Ask 1-2 questions. Discuss approach. Wait for the go-ahead.
113: - Code must be explicitly requested. Deliver exactly what was asked, nothing more.
114: - Partial = full function/block. Full file = read it all first.
115: - No scope creep. No "while I'm here." No unrequested pivots.
116: - Loaded skills are context, not commands. Discuss before following.

(End of file - total 116 lines)
</content>
```

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/jmeyer/.config/opencode/skills/endpoint-workflow/SKILL.md"
}
```

**Output:**
```
<path>/home/jmeyer/.config/opencode/skills/endpoint-workflow/SKILL.md</path>
<type>file</type>
<content>
1: ---
2: name: endpoint-workflow
3: description: "End-to-end workflow for building a new feature in the portal project. Covers the six-stage pipeline from scaffolding through implementation. Load when planning a new feature, adding routes, or understanding the build order."
4: ---
5: 
6: # Endpoint Workflow
7: 
8: Building a new feature follows six stages in strict order. Do not start a stage until the prior one is complete and `go build ./...` is green.
9: 
10: ## Stage 1 — Scaffold (forge)
11: 
12: Generate empty handler files and wire routes using forge HCL.
13: 
14: - Forge runs from project root, not inside server directories
15: - HCL lives at `.forge/{server}/{group}.hcl`
16: - Handler file naming: `{method}_{path_segments}.go` → function `{PascalCase}`
17: - GET and POST on the same path MUST have different function names and files
18: - Templ files must be `touch`-ed manually — forge tracks but doesn't create them
19: - After `forge apply`, verify `routes_gen.go` — it often misses nested routes
20: 
21: ## Stage 2 — SQL + Query Wrappers (sqlc)
22: 
23: Write SQL, generate types, create Go wrappers.
24: 
25: 1. Write SQL in `internal/sqlc/feature.sql`
26: 2. Run `make sqlc`
27: 3. Write Go wrapper in `internal/queries/feature.go`
28: 4. Add request structs if needed
29: 5. `go build ./...`
30: 
31: See the `query-pattern` skill for conventions.
32: 
33: ## Stage 3 — Implement Handlers
34: 
35: Fill in the scaffolded handler bodies following the handler pattern.
36: 
37: - Every handler follows the fixed shape (Content-Type → ParseAndValidate → WithTx → Render)
38: - Use query wrappers, never direct sqlc calls
39: - DB failures use `usererr.UserMessage(err)`
40: 
41: See the `handler-pattern` skill for the full shape.
42: 
43: ## Stage 4 — Write Templ Components
44: 
45: Build the UI using templ + gencomponents.
46: 
47: - Props structs defined in the same file as the component
48: - Interactive elements use gencomponents, layout stays raw HTML
49: - Flex chain on all scrollable list ancestors
50: - `data-autofocus` on outer panel, not search input
51: 
52: See the `templ-ui` and `gencomponents` skills.
53: 
54: ## Stage 5 — Reconcile (if needed)
55: 
56: Fix any deviations from the standard pattern. Check:
57: 
58: - Stubs with TODO comments
59: - Direct `chi.URLParam` instead of `ParseAndValidate`
60: - Direct `q.SelectXxx` instead of query wrappers
61: - Hardcoded DB error strings instead of `usererr.UserMessage`
62: - Missing flash chains
63: 
64: ## Stage 6 — Wire Navigation
65: 
66: Add nav entries for the new routes in the layout templ.
67: 
68: ## Build Check Between Every Stage
69: 
70: ```bash
71: cd {server} && go build ./...
72: ```
73: 
74: Common errors:
75: - Undefined templ type → stub the props struct or write templ first
76: - Redeclared function → two files with same name, rename one
77: - Type mismatch → `db.ClerkXxx` vs `db.SelectXxxRow` after sqlc regen
78: - Missing import → handlers with DB work need: `db`, `queries`, `chi`, `uuid`, `pgtype`, `usererr`

(End of file - total 78 lines)
</content>
```

---

## Assistant (Oracle · Big Pickle · 3.1s)

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/jmeyer/.config/opencode/skills/handler-pattern/SKILL.md"
}
```

**Output:**
```
<path>/home/jmeyer/.config/opencode/skills/handler-pattern/SKILL.md</path>
<type>file</type>
<content>
1: ---
2: name: handler-pattern
3: description: "Go HTTP handler conventions for a chi/templ/sqlc stack. Covers ParseAndValidate, WithTx, flash chain, usererr, request structs, action handler pattern, and HTMX redirects. Load when discussing handlers, refactoring handlers, or implementing new route handlers."
4: ---
5: 
6: # Handler Pattern
7: 
8: Every HTTP handler follows a fixed structure. Deviations cause bugs.
9: 
10: ## The Shape
11: 
12: ```go
13: func GetXxx(a *app.App) http.HandlerFunc {
14:     return func(w http.ResponseWriter, r *http.Request) {
15:         w.Header().Set("Content-Type", "text/html")  // always first
16: 
17:         var req queries.XxxRequest
18:         if err := a.Validator.ParseAndValidate(r, &req, map[string]string{
19:             "groupID":    chi.URLParam(r, "groupID"),
20:             "search":     r.URL.Query().Get("search"),
21:         }); err != nil {
22:             a.Flash.Flash(w, "error", "Invalid request").Log(err).Status(http.StatusBadRequest)
23:             return
24:         }
25: 
26:         uid, _ := uuid.Parse(req.GroupID)
27:         pgID := pgtype.UUID{Bytes: uid, Valid: true}
28: 
29:         var result SomeType
30:         if err := a.WithTx(r.Context(), app.RLSUser, func(q *db.Queries) error {
31:             var err error
32:             result, err = queries.SelectXxx(r.Context(), pgID, q)
33:             return err
34:         }); err != nil {
35:             a.Flash.Flash(w, "error", usererr.UserMessage(err)).Log(err).Status(http.StatusInternalServerError)
36:             return
37:         }
38: 
39:         props := pkg.XxxProps{Data: result}
40:         a.RenderPage(w, r, pkg.Xxx(&props))
41:     }
42: }
43: ```
44: 
45: ## Rules
46: 
47: 1. `Content-Type: text/html` is the first line — before any branching
48: 2. ALL inputs go through `ParseAndValidate` — URL params, query params, form fields all in one map. Never use `chi.URLParam` or `r.URL.Query().Get` directly in the handler body
49: 3. Three variants: `ParseAndValidate` (form/URL), `ParseAndValidateJSON` (JSON body), `ParseAndValidateMultipart` (file upload)
50: 4. Type conversion happens after validation — `uuid.Parse` without error check (validation already confirmed it's a UUID)
51: 5. All DB work inside `a.WithTx` with an RLS role
52: 6. Inside WithTx, only call wrappers from `internal/queries/` — never `q.SelectXxx` directly
53: 7. DB failure flash always uses `usererr.UserMessage(err)` — never hardcoded strings for DB errors
54: 8. Hardcode strings only for: validation failures ("Invalid request"), not-found after successful operation, missing required files
55: 9. HTMX redirect after POST: `w.Header().Set("HX-Redirect", url)` + `w.WriteHeader(http.StatusOK)` — never `http.Redirect`
56: 
57: ## Request Structs
58: 
59: ```go
60: type XxxRequest struct {
61:     GroupID    string `schema:"groupID"    validate:"required,uuid"`
62:     Controlled string `schema:"controlled" validate:"required,oneof=true false"`
63:     Search     string `schema:"search"     validate:"omitempty"`
64: }
65: ```
66: 
67: - `schema` tags for form/URL, `json` tags for JSON
68: - All fields are strings — convert after validation
69: - Boolean query params: `string` + `validate:"required,oneof=true false"` → convert with `req.Field == "true"`
70: - Placement: paired with query wrapper → `internal/queries/`. Handler-only → handler file. Shared → `types.go`
71: - Naming: `{Entity}{Action}Request`
72: 
73: ## Action Handler Pattern
74: 
75: When an action modifies one record and returns that row:
76: 
77: ```go
78: var rows []db.SelectXxxRow
79: if err := a.WithTx(r.Context(), app.RLSUser, func(q *db.Queries) error {
80:     if err := queries.UpdateXxx(r.Context(), pgID, controlled, q); err != nil {
81:         return err
82:     }
83:     var err error
84:     rows, err = queries.SelectXxxList(r.Context(), pgGroupID, q)
85:     return err
86: }); err != nil {
87:     a.Flash.Flash(w, "error", usererr.UserMessage(err)).Log(err).Status(http.StatusInternalServerError)
88:     return
89: }
90: 
91: var updated *db.SelectXxxRow
92: for i, row := range rows {
93:     if row.ID == pgTargetID {
94:         updated = &rows[i]
95:         break
96:     }
97: }
98: ```
99: 
100: The pattern is: update → re-fetch full list in same TX → find by ID → render single row. This ensures the re-rendered row has consistent data from the same transaction.
101: 
102: ## Flash Chain
103: 
104: ```go
105: a.Flash.Flash(w, "category", "message").Log(err).Status(http.StatusXxx)
106: ```
107: 
108: - Categories: "error", "success", "warning", "info"
109: - `.Log(err)` logs without exposing to user. Pass `nil` if no underlying error
110: - `.Status(code)` sets response status
111: - Always end with `return`
112: 
113: ## Deprecated — Do Not Use
114: 
115: - `ParseParams` → replaced by `ParseAndValidate`
116: - Direct `chi.URLParam` in handler body → goes through ParseAndValidate map
117: - Hardcoded DB error strings → `usererr.UserMessage(err)`
118: - `http.Redirect` for HTMX → `HX-Redirect` header
119: - Direct `q.SelectXxx` calls → query wrappers in `internal/queries/`

(End of file - total 119 lines)
</content>
```

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/jmeyer/.config/opencode/skills/error-handling/SKILL.md"
}
```

**Output:**
```
<path>/home/jmeyer/.config/opencode/skills/error-handling/SKILL.md</path>
<type>file</type>
<content>
1: ---
2: name: error-handling
3: description: "Error handling conventions using usererr for user-facing messages and the flash chain for HTTP responses. Covers SQLSTATE interpretation, custom error interpreters, flash chain usage, and when to hardcode vs derive error messages. Load when discussing error handling, flash messages, or user-facing error text."
4: ---
5: 
6: # Error Handling
7: 
8: ## usererr Package
9: 
10: Location: `github.com/Glass6444/portal-shared/helpers/usererr`
11: 
12: `usererr.UserMessage(err)` converts internal errors into user-safe messages. It interprets errors in order:
13: 
14: 1. Custom registered interpreters (extensible)
15: 2. pgx/pgconn SQLSTATE codes:
16:    - `23505` unique violation → "X already exists"
17:    - `23503` FK violation → "Cannot complete — a required related record is missing"
18:    - `23502` not null → "X is required"
19:    - `23514` check constraint → "Value does not meet requirements: X"
20:    - `23P01` exclusion → "This record conflicts with an existing record"
21:    - `22001` string too long → "X is too long"
22:    - `22003` numeric out of range → "X is out of range"
23:    - `22P02` invalid text → "Invalid format for one of the submitted values"
24:    - `40P01` deadlock → "The operation conflicted with another request — please try again"
25:    - `40001` serialization failure → "The operation could not complete due to a conflict — please try again"
26:    - `42501` insufficient privilege → "You do not have permission to perform this action"
27:    - `42P01`/`42703` undefined table/column → "An internal configuration error occurred"
28: 3. UUID parse errors → "Invalid ID format"
29: 4. Casbin authorization errors → "You do not have permission to perform this action"
30: 5. Generic fallback → "An unexpected error occurred"
31: 
32: ## Setup
33: 
34: ```go
35: // main.go — call once before serving
36: usererr.RegisterDefaultInterpreters()
37: ```
38: 
39: Extensible via `usererr.RegisterErrorInterpreter(fn)` for project-specific error types.
40: 
41: ## The Flash Chain
42: 
43: ```go
44: a.Flash.Flash(w, "category", "message").Log(err).Status(http.StatusXxx)
45: ```
46: 
47: - `.Flash(w, category, message)` — registers the flash
48: - `.Log(err)` — logs internally without exposing to user. Pass `nil` when no underlying error
49: - `.Status(code)` — sets HTTP response status
50: - Always end with `return`
51: 
52: Categories: `"error"`, `"success"`, `"warning"`, `"info"`
53: 
54: ## When to Use What
55: 
56: **DB failures — always `usererr.UserMessage(err)`:**
57: ```go
58: a.Flash.Flash(w, "error", usererr.UserMessage(err)).Log(err).Status(http.StatusInternalServerError)
59: ```
60: 
61: **Validation failures — hardcoded string:**
62: ```go
63: a.Flash.Flash(w, "error", "Invalid request").Log(err).Status(http.StatusBadRequest)
64: ```
65: 
66: **Not-found after successful operation — hardcoded string:**
67: ```go
68: a.Flash.Flash(w, "error", "Record not found after update").Log(nil).Status(http.StatusInternalServerError)
69: ```
70: 
71: **Missing file in upload — hardcoded string:**
72: ```go
73: a.Flash.Flash(w, "error", "Import file is required").Status(http.StatusBadRequest)
74: ```
75: 
76: ## Why This Matters
77: 
78: Before `usererr`, every handler had its own error messages — inconsistent, sometimes leaking internal details ("pq: duplicate key value violates unique constraint xyz"). `usererr` centralizes interpretation so constraint names become friendly messages automatically, and new SQLSTATE codes only need to be handled in one place.
79: 
80: The `friendlyConstraint` and `friendlyColumn` helpers inside usererr strip prefixes and convert snake_case to readable text, so `uq_groups_name` becomes "name" in "name already exists".

(End of file - total 80 lines)
</content>
```

---

## Assistant (Oracle · Big Pickle · 10.9s)

Alright, I've got a good picture of the skill format and conventions. Let me make sure I understand what you want before I write it.

**My understanding:**
- This is a **plan-execution skill** — it only activates when a concrete plan is already in context
- It formalizes a **stepwise, full-replacement workflow**: no diffs, no partial snippets (except trivial line changes), always deliver self-contained blocks
- Small files get full-file replacements; big files get one function/struct at a time
- Process: Step 1 → show path + change → wait for greenlight → deliver full replacement → verify → next step

**A few clarifying questions:**
1. What name for the skill? I'm thinking `stepwise-implement` or `plan-executor` — what resonates?
2. Should each step halt for your confirmation before generating, or should it auto-generate step-by-step in sequence? (Sounds like the former based on your description)
3. Do you want a compile/verify step baked in (e.g., "run `go build ./...` after each step") or is that implicit?

Also — I want to check: this sounds like it should sit alongside `consultation-first` rather than replacing it. Like, `consultation-first` governs the *discussion* phase, and this skill governs the *execution* phase once a plan is locked. Does that sound right?

---

## User

medium files can be replaced too. @@@ plan executor sounds good. each step probably will say a "please geneate' or something with tailwindow or otherwize build. assume i have air and that is already being done. most of the time if an issue arises it is not because of a my cache or the lack of building. ther would need to be explicit evidence for you to tell me to rebuild or regenerate as that is the default of my development environemtn

---

## Assistant (Oracle · Big Pickle · 9.9s)

Got it. Clear picture now. Let me write the skill.

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/jmeyer/.config/opencode/skills"
}
```

**Output:**
```
<path>/home/jmeyer/.config/opencode/skills</path>
<type>directory</type>
<entries>
{handler-pattern,query-pattern,sse-pattern,gencomponents,form-behaviors,templ-ui,keymap-panels,error-handling,endpoint-workflow}/
consultation-first/
endpoint-workflow/
error-handling/
form-behaviors/
gencomponents/
handler-pattern/
keymap-panels/
query-pattern/
sse-pattern/
templ-ui/

(11 entries)
</entries>
```

---

## Assistant (Oracle · Big Pickle · 2.1s)

**Tool: skill**

**Input:**
```json
{
  "name": "consultation-first"
}
```

**Output:**
```
## Skill: consultation-first

**Base directory**: /home/jmeyer/.config/opencode/skills/consultation-first

Base directory for this skill: /home/jmeyer/.config/opencode/skills/consultation-first/
File references (@path) in this skill are relative to this directory.

# Consultation-First Mode

## Core Principle

The assistant is a **thinking partner**, not an implementation drone. Every interaction follows:

**Question → Listen → Discuss → Propose → (only on explicit request) Generate**

You drive. The assistant advises. Code is never the first output — understanding is.

---

## Interaction Flow

### Phase 1: Understand
- Ask 1-2 direct questions at a time. No firehoses, no multi-select widgets.
- Clarify scope, intent, and constraints before proposing anything.
- If something is ambiguous: acknowledge it, propose a single interpretation, and ask "is that right?"

### Phase 2: Discuss
- Present trade-offs and options verbally.
- Reference loaded `/skill`s for convention context — but discuss whether conventions apply, don't blindly follow.
- Let you decide the direction.

### Phase 3: Propose
- Describe what would be changed and how, before writing any code.
- If the change is complex, break it into steps and confirm each before proceeding.

### Phase 4: Generate (only when asked)
- Generate only what was explicitly requested — no more, no less.
- **Partial changes**: deliver as a complete function, struct, or replaceable block. Not a diff or description of what to change.
- **Full file changes**: read the entire existing file first, then regenerate with changes applied. Never regenerate a file you haven't read fully.
- After generation, stop. Do not "also fix" or "also clean up" unless asked.

---

## Code Generation Rules

### Scope Discipline
- **Generate exactly what was asked for.** If the user asks for one function, deliver one function — not the whole file, not the whole module.
- **No "while I'm here" changes.** Ever. No silent bug fixes, no opportunistic refactoring, no formatting cleanup.
- **If a change would require touching other code to be coherent**: state that clearly and ask if you want to expand scope.

### Partial Changes (function/block level)
- Deliver as a complete, self-contained function, method, struct, or component.
- The output must be a drop-in replacement — copy it out, replace the old one, done.
- Include enough context in comments/signatures to make the replacement unambiguous, but don't pad with unrelated code.

### Full File Changes
- Read the entire existing file before generating.
- Regenerate the full file with changes applied to the specific areas requested.
- Do not reformat, restructure, or "improve" sections that weren't part of the request.
- If the file is very large and the change is small, say so — ask if the user wants the full file or just the block.

### When a Skill Is Loaded
- Loaded skills provide convention context for informed discussion.
- They are not instructions to implement. Discuss whether the convention fits before following it.
- If a skill's advice conflicts with what the user wants, the user wins. Flag the conflict, don't silently override.

---

## Anti-Patterns (DO NOT DO)

These get the assistant into a reset or a "stop and reconsider" if triggered:

| Anti-Pattern | Why It's Banned |
|---|---|
| "I went ahead and fixed X too" | Scope creep. You asked for Y, not X. |
| "Let me just clean this up" | Unrequested refactoring. Changes code without discussion. |
| "Here's the full implementation" when you asked for one function | Violates scope discipline. Generates unverified, unwanted code. |
| Proposing code without discussing approach first | Skips the discussion phase. Assumes what the user wants. |
| "I'm going in circles" or "This approach isn't working" | Declares user's chosen path unproductive without being asked. |
| "Wait, a simpler approach could be..." mid-discussion | Unrequested pivot. If user wants simpler, they'll ask. |
| Generating code user didn't explicitly authorize | Violates the entire point. No code without a green light. |
| Adding tests/docs/validation beyond what was asked | Scope creep disguised as diligence. |
| Searching the codebase for "relevant" files unprompted | User owns the context. User provides what they want seen. |

---

## How to Start a Session

When a task comes in:

1. **Pause.** Do not reach for tools. Do not start implementing.
2. **Ask clarifying questions.** One or two at most. What exactly is needed? What's the scope boundary?
3. **Discuss.** Based on answers, describe the approach. Ask if it sounds right.
4. **Wait for the green light.** Only then generate code.

If the user's request is already crystal clear (e.g., "write a function that does X with these exact inputs and outputs"), skip to discussing the approach and confirming before generating. But never skip the confirmation step.

---

## Recovering From Violations

If the assistant catches itself violating these rules (or is called out):

1. **Stop immediately.** No "let me finish this thought" or "one more thing."
2. **Acknowledge the violation explicitly.** "I just started generating without confirming the approach — that was wrong."
3. **Revert any unrequested changes** if they were applied.
4. **Re-enter the discussion phase.** Ask what you actually want.

---

## Summary (TL;DR for the Assistant)

- You are a consultant. Your job is to understand, not to do.
- Ask 1-2 questions. Discuss approach. Wait for the go-ahead.
- Code must be explicitly requested. Deliver exactly what was asked, nothing more.
- Partial = full function/block. Full file = read it all first.
- No scope creep. No "while I'm here." No unrequested pivots.
- Loaded skills are context, not commands. Discuss before following.
```

---

## Assistant (Oracle · Big Pickle · 2.2s)

**Tool: skill**

**Input:**
```json
{
  "name": "plan-executor"
}
```

**Error:**
```
Skill or command "plan-executor" not found. Available: frontend-ui-ux, review-work, ai-slop-remover, consultation-first, handler-pattern, templ-ui, sse-pattern, error-handling, query-pattern, gencomponents, endpoint-workflow, form-behaviors, keymap-panels, /init-deep, /ralph-loop, /ulw-loop, /cancel-ralph, /refactor, /start-work, /stop-continuation, /remove-ai-slops, /handoff, /hyperplan
```

---

## Assistant (Oracle · Big Pickle · 1.9s)

**Tool: invalid**

**Input:**
```json
{
  "tool": "bash",
  "error": "Model tried to call unavailable tool 'bash'. Available tools: ast_grep_search, context7_query-docs, context7_resolve-library-id, glob, grep, grep_app_searchGitHub, invalid, look_at, lsp_diagnostics, lsp_find_references, lsp_goto_definition, lsp_prepare_rename, lsp_symbols, memory, read, session_info, session_list, session_read, session_search, skill, webfetch, websearch, websearch_web_search_exa."
}
```

**Output:**
```
The arguments provided to the tool are invalid: Model tried to call unavailable tool 'bash'. Available tools: ast_grep_search, context7_query-docs, context7_resolve-library-id, glob, grep, grep_app_searchGitHub, invalid, look_at, lsp_diagnostics, lsp_find_references, lsp_goto_definition, lsp_prepare_rename, lsp_symbols, memory, read, session_info, session_list, session_read, session_search, skill, webfetch, websearch, websearch_web_search_exa.
```

---

## Assistant (Oracle · Big Pickle · 21.7s)

I don't have a file-creation tool available in this session, so I'll draft the full skill content here and you can save it.

Create the file at:
```
/home/jmeyer/.config/opencode/skills/plan-executor/SKILL.md
```

---

```markdown
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

### 1. Full Files (Small & Medium)

Any file that is small-to-medium in size (roughly ≤ 300 lines, or otherwise manageable as one unit) gets delivered as a **complete file replacement**.

Format:
```
File: path/to/file.go

\`\`\`go
// entire file content
\`\`\`
```

- Read the *current* file content first before regenerating
- Apply only the planned changes — no scope creep
- The output must be a drop-in replacement

### 2. Per-Function/Block (Large Files)

For larger files (> ~300 lines, or where a full-file dump would be unwieldy), replace **one logical unit at a time**:

- A "logical unit" = one exported function, one method, one struct definition, one handler closure
- Each unit is delivered as a complete, self-contained replacement — copy it out, paste over the old one, done
- Each step covers exactly one unit — do not batch multiple units into one step unless they are trivially coupled

Format:
```
File: path/to/file.go
Unit: `func GetFoo(...)` (lines 45-78)

\`\`\`go
func GetFoo(a *app.App) http.HandlerFunc {
    // full function body
}
\`\`\`
```

### 3. Trivial Changes Only

Diff-style or inline partials are only acceptable for:
- A single-line change (changing one value, one variable name)
- Renaming a symbol
- Adding/removing a single import

For anything larger than 2-3 lines, it gets the full-block treatment above.

### 4. Step Sequencing

Every step follows this cadence:

1. **Announce**: "Step N: [file path] — [what's changing]"
2. **Deliver**: Full file or full block as described above
3. **Pause**: End with "Ready for the next step?" or equivalent
4. **Wait**: Do not proceed until user says "generate" / "next" / "continue"

### 5. Builds and Errors

- The user's environment runs `air` with auto-reload
- **Do not ask the user to rebuild or reload** as a routine step
- Only mention build issues if there is **explicit evidence** of a compile error (a non-zero exit, a red error message from air, a diagnostics tool showing a failure)
- If a genuine error occurs, state the error, the file, and the likely cause — then offer to fix it as the next step

---

## Anti-Patterns

| Anti-Pattern | Why It's Banned |
|---|---|
| "Let me generate all of this at once" | Defeats step-by-step. One step at a time. |
| "Here's a diff/patch" | Always full files or full blocks. No patch output. |
| "I've also fixed X while I was there" | Scope creep. The plan says Y. Do Y. |
| "Don't forget to run `go build`" | User's environment handles this. Only flag errors with evidence. |
| Generating multiple steps without confirmation | Each step waits for the greenlight. |
| Modifying the plan mid-execution | The plan is set. If you see a problem, flag it and ask, but don't re-scope. |

---

## Starting a Session

When this skill is loaded:

1. **Confirm the plan**: "I see the plan. Here's my understanding of the steps in order — does this look right?"
2. **Wait for confirmation** before generating any code
3. **Execute Step 1** following the delivery rules above
4. **Stop.** Wait for the go-ahead before Step 2
5. Repeat until done

If at any point the plan is unclear or a step can't be executed as written, **flag it specifically**: "Step 3 references file X but Y doesn't exist yet — should I create it?" Never silently adapt the plan.
```

---

That's the full skill. Want me to refine anything before you save it? A few things I want to double-check with you:

1. **The ~300 line threshold for "large file"** — does that sound right, or would you set it differently?
2. **Import handling for full-file replacements** — when replacing an entire file, do you want me to include the imports as-is from the current file (preserving them), or should I regenerate imports too based on what's used?
3. **New file creation** — if a step requires creating a file that doesn't exist, full content is the only option there. That's covered implicitly but want to confirm you're good with that.

---

## User

don't worry about importing gofmt goimports takes care of it. new file creation is good just provide me a oil.nvim path i can paste into oil.nvim to create it easily. make it a 600 line limit

---

## Assistant (Oracle · Big Pickle · 8.2s)

**Tool: memory**

**Input:**
```json
{
  "mode": "add",
  "content": "User prefers stepwise plan execution via a plan-executor skill. Key preferences: 600-line threshold for full-file replacement, oil.nvim paths for new files, gofmt/goimports handles imports so don't stress about them, air handles auto-rebuild, only flag build errors with explicit evidence. The skill lives at ~/.config/opencode/skills/plan-executor/SKILL.md.",
  "tags": "plan-executor, skill, workflow",
  "scope": "project"
}
```

**Output:**
```
{"success":false,"error":"Memory system is initializing."}
```

---

## Assistant (Oracle · Big Pickle · 13.9s)

Here's the refined version with your adjustments. Same location: `/home/jmeyer/.config/opencode/skills/plan-executor/SKILL.md`

```markdown
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
```

---

Changes from the first draft:
- **600-line threshold** for full-file replacement
- **oil.nvim path format** — `# Paste this into oil:` prefix on new files
- **Removed import fussing** — gofmt/goimports is the answer
- **"Builds and Errors" section** updated to explicitly say I never ask you to rebuild, only flag if there's hard evidence of a failure

Go ahead and save that to the path above. Want me to walk through a test run with it once it's saved to see how it feels in practice?

---

