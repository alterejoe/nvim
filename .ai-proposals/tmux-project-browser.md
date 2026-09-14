# Tmux project browser redesign

## Approved behavior

- Keep `scratchbuf` generic. Project/group/path semantics remain inside `tmux_projects`.
- Replace the current `tp` picker → group drill-down flow with an Oil-style flat browser.
- The browser displays one level at a time. Entering a group replaces the buffer contents with that group's children; an up action returns to the parent.
- Groups are containers only. Pressing Enter on a group never creates or opens a tmux session.
- Only session entries create or switch tmux sessions.
- Session rows show both editable fields inline:

  `session-name    ~/projects/group/session-name`

  Both fields remain ordinary buffer text and are edited with the existing `i`, `o`, and `O` behavior. No hidden path state.
- Group rows are visually distinct from sessions with a folder marker/highlight. Path text is visually secondary but remains real editable text.
- New group rows use a trailing `/`; new session rows use the two-field format.
- Paths may be typed directly and are not restricted to the current directory picker search roots.
- Derived paths are only a convenience/default; an explicit path in the row always wins.
- The parent/up navigation key returns to the previous group level; the top level returns to the group list.

## Persistence

- Make the JSON store the single source of truth for project groups and sessions.
- Migrate the current hardcoded `after/plugin/tmux.lua` project definitions into JSON on first load when needed.
- Do not merge two independently authoritative sources after migration.
- Preserve session order, group order, active project, hidden-session behavior, and default sessions.

## Existing functionality to preserve

- Session creation, switching, renaming, deletion, reordering, and path updates.
- Project switching that closes sessions outside the selected project.
- Recovery of the active project.
- Opencode-session visibility toggle.
- The separate `ts` live-session editor for currently running sessions.
- Existing tmux split, join, break, kill-all, and slot keymaps.

## Scratchbuf/performance changes

- Keep the current editable-buffer interaction model.
- Replace the blocking per-keystroke filter redraw path with an incremental/debounced implementation.
- Cache tmux session state for a browser instance and refresh it only on the refresh action or after an operation that changes sessions.
- Cache directory candidates instead of rescanning all roots on every picker invocation.
- When outside tmux, allow the project browser to open for editing and show a visible status; tmux-only actions must not silently do nothing.

## Implementation order

1. Add the flat browser model, navigation state, row rendering, and inline name/path parsing.
2. Add JSON migration and single-source persistence.
3. Preserve and reconnect tmux actions and `ts`.
4. Apply scratchbuf filtering, tmux-state, directory-scan, and outside-tmux activation fixes.
5. Run diagnostics and verify the existing browser scratchbuf consumer remains compatible.
