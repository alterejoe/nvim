# Personal Rules

## Communication Style
- Do not think silently for long stretches. Interpret what I give you and talk to me about it.
- Default to conversation, not execution. Discuss your understanding and approach before writing code or making changes.
- If something is ambiguous, ask - don't guess and run with it.
- Keep responses short and direct. No essays, no filler.
- When I give you a task, confirm what you're about to do in a sentence or two before doing it.
- If you hit a problem or unexpected result, stop and tell me immediately instead of trying multiple fixes on your own.

## Output Format
Every code block in every response MUST conform to ALL of the following:

1. **Path comment on line 1** — The first line of every code block is a comment identifying the file path:
   - `// path/to/file.go` for Go, JavaScript, TypeScript, C, etc.
   - `# path/to/file.py` for Python, Ruby, YAML, shell scripts, etc.
   - `-- path/to/file.lua` for Lua, SQL, etc.
   - No exceptions. No blank lines before it.

2. **Language tag on the fence** — Every fenced code block MUST have a language tag: ` ```go`, ` ```python`, ` ```typescript`, etc. Unmarked fences (` ``` `) are not permitted.

3. **Summary headings** — Every section that introduces code blocks MUST begin with a brief heading describing what the code does.

4. **Explicit delivery metadata** — Every code block MUST be preceded by a line stating the operation type:
   - `Full replacement:` — the entire file content follows
   - `New file:` — this is a brand-new file
   - `Block: \`func X\`` — this is a single-function/block replacement
   - Names and specifics inline so no ambiguity

5. **FINAL marker for versioning** — When a code block is the definitive version, the path comment MUST end with ` FINAL` (first final) or ` FINAL-n` (n increments each time the block is revised for the same file in the same response). The picker uses this to show only the latest version per file. Examples:
   - `// path/to/file.go FINAL` — first final version
   - `// path/to/file.go FINAL-2` — revised final (overrides earlier FINAL and FINAL-1)

## Plan Execution
When a comprehensive plan has been discussed and agreed upon and is ready to execute, use the `/plan-executor` skill to proceed step by step. Validate with the user first, but the vast majority of generation work follows this style: full-file or full-block replacements only, no diffs or partials.
