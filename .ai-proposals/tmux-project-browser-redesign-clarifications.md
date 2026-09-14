# Tmux project browser clarifications

These clarify the approved inline editing and creation behavior:

- A line ending in `/` is a group/container declaration. Typing `test/` creates or enters the `test` group; it must not open a path picker and must not create a tmux session.
- A line without a trailing `/` is a session declaration. Typing `test/test` creates a session entry and may request/derive its working path.
- The path workflow must allow manual entry. A path does not need to exist or appear in a picker to be accepted and stored.
- A path picker may still provide existing directory completion, but it must include a manual-input path that accepts arbitrary text.
- Group rows and session rows remain visually distinct. The trailing slash is the editable semantic marker, not merely decoration.
