# HANDOFF — opencode-manage managed read tool (phase work)

**Pull this into a new session to resume.** Source session `ses_f0d9de202ffeIRZpNfdq6gCF63` (2026-09-30 12:55–14:47, 228 msgs) is unreachable via `session_read` (index gap) but searchable via `session_search` with `session_id` filter.

## Goal
Replace the raw `read` tool with a **daemon-gated managed read** ("airlock"): reads proxy through the Go daemon's `/v1/read` endpoint, which enforces a **folders table** (approved paths) and returns gated/redacted content. Fail-closed by design. Work spans three repos: `~/projects/opencode-manage` (Go daemon), `~/.config/opencode/plugins` (TS plugin), `~/.config/nvim/lua/opencode-manage` (nvim console).

## Done — Phase 1 "Foundation" (group `phase1-read-tool`, ALL 8 proposals ACCEPTED, on disk)
- `projects/opencode-manage/internal/handlers/read.go` — daemon `/v1/read` endpoint, folders-table gating, fail-closed
- `projects/opencode-manage/internal/handlers/proposals.go` — `/v1/read` wired into Mount
- `.config/opencode/plugins/lib/tools/read.ts` — read tool override proxying to daemon
- `.config/opencode/plugins/manage.ts` — read tool registered
- `projects/opencode-manage/Makefile` — `restart` target + pkill self-match fix
- `.config/nvim/lua/opencode-manage/daemon.lua` — `:ManageDaemonRestart` helper
- `.config/nvim/lua/opencode-manage/init.lua` — command registered

## Activation (from the vanished session)
```bash
cd ~/projects/opencode-manage && go build -o bin/manage ./cmd/manage
```
Then restart the daemon: `make restart` or `:ManageDaemonRestart` in nvim.

## ⚠️ Live gotcha — reads are now gated and the folders table is empty
After activation, the managed read tool denies ALL reads outside the project workspace (`[manage] read denied: ... not covered by an approved folder`). `~/projects/opencode-manage` and `~/.config/opencode/plugins` are currently unreadable. Fix: approve folders via the nvim folders panel (`<leader>aa`), or seed the daemon's folders table from `opencode.json` `permission.external_directory` (`~/.config/opencode/**`, `~/docs/**`, `~/infra/alterejoe/terraform/**`, `~/projects/shared/**`). Decide which is intended — this is likely the next design question.

## Next — Phase 2+ (plan text is in the vanished session)
The full phased plan was presented at 14:19:23 (msg `0f2af356b001X7Hg2JBlDJQFGX`): "1. **Foundation (Medium):** load the manage plugin in *all* sessions..." — truncated in search. Recover it via `session_search(query="phase", session_id="ses_f0d9de202ffeIRZpNfdq6gCF63")` or have the user restate. Phase 1 was the only one implemented.

## Key references
- `projects/opencode-manage/docs/refactor-plan.md` — M1–M7 done, M8 (registry/skills/refs → daemon) TODO
- `projects/opencode-manage/docs/architecture.md` — V1 plugin shape `{ id, server }` via `readV1Plugin`
- Engram memory #192 — thin-client audit: TS lib is fat (~2900/4300 lines), daemon owns proposals/work-items/events only
- Engram memory #171 — oracle persona shadow (fixed separately, group `unshadow-oracle-persona`, pending)
- `plugins/lib/airlock.ts` — existing permission-layer logic the read tool builds on

## Session recovery note
`session_info` resolves the session but `session_read` does not. Transcript lives in `~/.local/share/opencode/storage/session_diff/ses_f0d9de202ffeIRZpNfdq6gCF63.json` (read denied — needs folder approval). `session_search` works as the fallback.

## Note
An older `handoff.md` exists at `~/projects/opencode-manage/.ai-proposals/handoff.md` (unreadable to me — folders gating). Check it before resuming; it may hold the phase 2+ plan. Approve the folder if you want it merged into this one.
