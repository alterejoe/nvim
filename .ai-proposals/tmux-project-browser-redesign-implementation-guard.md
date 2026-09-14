# Required implementation guard: classify rows before path selection

The current implementation treats every newly added line as a session and calls `state.pick_directory()`. This is the source of the trailing-slash inconsistency.

Required save behavior:

1. Read the raw edited line before trimming away its semantic suffix.
2. If the trimmed line ends in `/`, classify it as a group/container:
   - strip only the marker slash for the stored group name;
   - create/update the group node;
   - do not call `state.pick_directory()`;
   - do not create or switch a tmux session.
3. Otherwise classify it as a session:
   - parse the editable session name and path fields;
   - use the explicit path if supplied;
   - only if the path field is empty, offer derived-path handling or the existing-directory picker;
   - manual path text must be accepted without requiring picker membership.
4. This classification must happen before any generic `created` callback or path-prompt loop, so `test/` can never open the session path picker.

Add regression coverage/manual verification for:

- `test/` creates a container without opening a picker.
- `test/test` creates a session entry.
- `test/test    /path/that/does/not/exist` saves directly without a picker.
