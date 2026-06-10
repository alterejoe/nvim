# Output Formatting Rules

These rules are mandatory. The viewer.lua parser silently discards blocks that don't match. Every rule below is enforced by a specific parser function — violations mean the code never appears in the picker.

## Rule 1: Path Comment on Line 1

Every fenced code block MUST start with a comment identifying the file path on the very first line.

Valid comment prefixes (matching `strip_comment` + `is_path_comment`):
- `//` (Go, JS, TS, C, Rust, etc.)
- `#` (Python, Ruby, YAML, shell, etc.)
- `--` (Lua, SQL, etc.)

Format: `{prefix} {path}`

The path must:
- Use only `[%w_%-/%.~]` characters (alphanumeric, underscore, hyphen, dot, tilde, forward slash)
- End with a valid extension from the parser's list (must match VALID_EXTS in viewer.lua — includes `.go`, `.templ`, `.ts`, `.tsx`, `.js`, `.jsx`, `.py`, `.rb`, `.rs`, `.lua`, `.sql`, `.md`, `.yaml`, `.yml`, `.json`, `.xml`, `.css`, `.scss`, `.html`, `.htm`, `.sh`, `.bash`, `.zsh`, `.toml`, `.cfg`, `.conf`, `.env`, `.gitignore`, `.dockerfile`, `.mjs`, `.cjs`, `.mts`, `.cts`, `.dart`, `.kt`, `.swift`, `.c`, `.cpp`, `.h`, `.hpp`)

Examples:
```
// handlers/auth.go
# models/user.py
-- schema/users.sql
```

**Parser consequence:** `detect_path` (line 55) fails → path is `""` → block shows no path icon, can't be opened with `o`. Severity: **HIGH** — block is orphaned.

## Rule 2: Partial Replacement Line Numbers

For partial file replacements, append `:{line}` or `:{start}-{end}` after the path, before any FINAL marker.

Format: `{prefix} {path}:{line} {FINAL?}` or `{prefix} {path}:{start}-{end} {FINAL?}`

Examples:
```
// handlers/auth.go:42 FINAL
// handlers/auth.go:42-58 FINAL
```

The parser extracts the path correctly by stopping at the `:` separator. The line number is not yet consumed by the viewer but is reserved for future line-jumping on `o`.

**Parser consequence:** Without line suffix, partial blocks look identical to full-file replacements. The line number is informational-only in the current viewer — no functional issue.

## Rule 3: FINAL Version Markers

When a code block is revised for the same file, append a version marker to the path comment to enable deduplication.

Formats (matching `detect_version` line 82-98):
- `FINAL` — version 1 (first final version)
- `FINAL-N` — version N where N increments (e.g., `FINAL-2`, `FINAL-3`)

The marker MUST be at the very end of the stripped first line (after any line-number suffix).

Examples:
```
// handlers/auth.go FINAL
// handlers/auth.go FINAL-2
// handlers/auth.go:42 FINAL
// handlers/auth.go:42-58 FINAL-2
```

**Parser consequence:** `detect_version` (line 82) checks for `FINAL$` or `FINAL-N$` at the end. If no FINAL marker is found, the block is treated as version 0. In a response with mixed FINAL/non-FINAL blocks for the same file, `dedupe_by_final` (line 308) drops ALL non-FINAL blocks for that path. Severity: **HIGH** — non-FINAL blocks silently disappear.

If no block for a path has FINAL, `dedupe_by_final` keeps ALL blocks. So omitting FINAL everywhere is safe but wasteful.

When revising, always increment: never output `FINAL-2` when the first version was also `FINAL-2` — the deduplicator picks the highest version.

## Rule 4: Language Tag on Code Fence

Every fenced code block opening line MUST include a language tag.

Format: ```` ```{lang} ````

Examples:
````
```go
```typescript
```python
```lua
```sql
```yaml
```json
````

**Parser consequence:** `model.lua` line 12 extracts `cb.lang = lines[i]:match("^```(.+)") or ""`. When no language tag is present, the snippet display shows `(?)` instead of `(go)`. Low severity for display only — does not affect path resolution.

## Rule 5: Step Headers for Context Labeling

When code blocks belong to a numbered step, mark that step in the surrounding text using `Step N:` format. This labels the picker entries.

The `detect_steps` function (line 147) scans the 5 lines of context before each code block for `Step N`. The step label is prepended to the picker display line.

Format in surrounding prose:
```
**Step 1: `handlers/auth.go` — Add login handler**
```

The backtick path after the colon is used by the picker label extraction but is not required for step detection — only `Step N` matters.

**Parser consequence:** Without step headers, the picker shows only the file path and snippet, making navigation harder in long responses with many blocks. Low severity — cosmetic.

## Rule 6: No Blank Lines Before Path Comment

The path comment must be the first line of the fenced code block. No blank line between the opening fence ` ``` ` and the path comment.

Good:
````
```go
// handlers/auth.go FINAL
package auth
```
````

Bad (blank line after fence):
````
```go

// handlers/auth.go FINAL
package auth
```
````

**Parser consequence:** `detect_path` reads `lines[1]` — if it's blank, the path check fails on the empty string. Fallback `extract_filenames` might eventually find the path from the text, but it's fragile. Severity: **MEDIUM** — path resolution degrades to fuzzy matching.
