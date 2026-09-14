# Tmux project browser navigation clarifications

## Refresh

- Map `<C-l>` buffer-locally in the project browser to refresh the current level.
- Refresh must reload the current group's children and live tmux status without losing the current folder context or cursor when possible.
- Keep the generic scratchbuf refresh key as-is for other consumers.

## Folder creation and entry

- `test/` is a folder/group declaration, never a tmux session.
- Saving `test/` must not call `tmux new-session`, must not report a created session, and must not invoke the path picker.
- The folder should appear in the current browser level and be immediately enterable.
- Pressing Enter on `test/` opens a new empty child view for that folder. It must not create or switch a session.
- The empty child view remains a valid editable scratch buffer; adding a non-trailing-slash row there creates a session belonging to `test`.
- Saving an empty folder is valid and persists the folder with zero sessions.
- The browser needs parent context so the up action returns from `test/` to its containing level.

## Regression checks

- Create `test/`; verify no tmux session exists and no path picker opens.
- Enter `test/`; verify the view is empty except for the normal help/status hints.
- Add `something`; assign/type its path; save; verify only then that the session is created or becomes available to open.
- Press `<C-l>` inside `test/`; verify the empty/current child view refreshes without jumping to the root.
