# Loop Guard

Detects the assistant stuck in a tight loop on the same named object and
escalates: a soft nudge, then a hard interrupt (session abort).

## Files

- `~/.config/opencode/plugins/lib/loopguard.ts` — the guard itself.
- `~/.config/opencode/plugins/manage.ts` — the wiring.

## Detection model

Consecutive-run, **not** cumulative. A *run* is the same tool-touch repeated
in a row; any different touch resets the run. Legitimate scattered re-reads
of a file (e.g. reading `foo.go` four times spaced across a turn) never trip
it. Only a tight loop does.

A "touch" is one of the named-object tags already produced in
`tool.execute.after`: `file`, `dir`, `pattern`, `symbol`, `skill`, `group`,
`subject`, `ref`. The run key is the sorted set of `kind\u0000tag` pairs for
a single tool call.

## Thresholds

Env-overridable, read once at module load:

| Env var                   | Default | Meaning                         |
|---------------------------|---------|---------------------------------|
| `LOOPGUARD_NUDGE_AT`      | `4`     | Consecutive touches → nudge     |
| `LOOPGUARD_INTERRUPT_AT`  | `8`     | Consecutive touches → interrupt |

## Exports

- `observe(sessionID, tags)` → `LoopSignal` (`none` / `nudge` / `interrupt`).
  Increments the run for the session, returns the strongest signal reached.
- `resetTurn(sessionID)` — clears a session's run state (called on new user
  message).
- `nudgeText(kind, tag, count)` — builds the injected nudge text.
- `recordInterrupt(directory, sessionID, kind, tag, count)` — writes a
  `loop_interrupt` row to the event store (observability).
- `NUDGE_AT` / `INTERRUPT_AT` — the resolved thresholds.

## Wiring in `manage.ts`

| Location                 | What happens                                             |
|--------------------------|----------------------------------------------------------|
| import (`:76-80`)        | Imports the four functions                                |
| `pendingLoopNudges` Map  | Module-scope stash, keyed by `sessionID` (`:126`)         |
| `tool.execute.after`     | `observe(...)` after `recordEvent` (`:370`). On interrupt: `recordInterrupt` then `client.session.abort({ path: { id: input.sessionID } })` (`:380`). On nudge: stash into `pendingLoopNudges` (`:385`). |
| `chat.message`           | `resetTurn(sessionID)` + clear the pending nudge (`:443`) |
| `messages.transform`     | After `reclaimContext`, inject a pending nudge into the last user message (`:508`), mirroring the verdict loop |

## Escalation timing (important)

- **Nudge** lands in the **next turn's** context — `messages.transform` runs
  *before* tool calls, so a nudge stashed mid-turn is only injected on the
  following turn. It is a heads-up, not a same-turn stop.
- **Interrupt/abort** fires immediately mid-turn. The abort is the real
  loop-stopper.

## Testing

1. Unit (no session, no wiring):
   ```bash
   cd ~/.config/opencode
   LOOPGUARD_NUDGE_AT=2 LOOPGUARD_INTERRUPT_AT=3 bun -e '
   import { observe, resetTurn } from "./plugins/lib/loopguard.ts";
   const s = "t";
   for (let i = 1; i <= 3; i++) {
     const sig = observe(s, [{ tag: "x.md", kind: "file" }]);
     console.log(i, sig.type);
   }
   '
   ```
   Expect `none`, `nudge`, `interrupt`.

2. Live: restart opencode, then prompt the model to read one file N times in a
   row. Watch for the abort at the interrupt threshold and a
   `loop_interrupt` row in the event store.

## Open risk

The abort call is `(client as any).session.abort(...)` — an **unverified**
API surface. If it does not exist on the client, interrupts no-op silently
while nudges still work. The live test is what proves the abort path.

## Restart requirement

The plugin is loaded and hooks are registered at opencode startup. Any edit
to `loopguard.ts` or `manage.ts` requires an opencode restart to take effect;
there is no build step (bun loads the `.ts` directly).
