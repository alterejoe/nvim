# /home/jmeyer/.config/nvim/.opencode/registry-summary.md FINAL
# Registry Summary — nvim

Generated from `.opencode/manage.registry.json`. LSP-verified refs
land via `registry_propose` as entries merge. Files under `_old/`
are archived by the snapshot system — treat as dead consumers.

## shared

### ../opencode/plugins/lib/refs.ts [FRAGILE]
- Symbols: loadFocus, matchRefs, lookupRefs
- Why: Shared reference-reading boundary for manage focus routing and ref_lookup. It must resolve explicit home-relative live refs without rewriting correction paths or proposal/verdict history.
- Used by: ../opencode/plugins/manage.ts, ../opencode/plugins/manage.ts, ../opencode/plugins/manage.ts

### lua/opencode-manage/refs.lua [FRAGILE]
- Symbols: index, pin, request_focus, list, list_global
- Why: The reference store is shared by commands, focus updates and both viewers. Home-relative storage must resolve at this boundary so callers still receive absolute paths; proposal/verdict history is outside its scope.
- Used by: lua/opencode-manage/init.lua, lua/opencode-manage/foldersview.lua, lua/opencode-manage/refsview.lua, lua/opencode-manage/vaultview.lua

## consolidations

### lua/opencode-manage/registry.lua, lua/opencode-manage/skills.lua
- Why: pretty_json (2-space, sorted keys) is duplicated verbatim: registry.lua keeps a module-private copy and skills.lua carries a copy explicitly flagged in its header. Both write hand-reviewed JSON manifests — they must stay byte-identical. Extract to a shared lua/opencode-manage/json.lua (pretty).
- Suggested target: lua/opencode-manage/json.lua
