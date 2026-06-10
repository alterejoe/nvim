---
name: admin-panel-audit
description: "Per-panel evaluation framework for updating the admin server's proofing pages. For each admin page/panel, identifies what POST handlers exist, what proofing records they touch, what visual changes are needed, and what the client server reference is. Use when planning work on a specific admin proofing page."
---

# Admin Panel Audit

## Prerequisite Skills

Load before using this skill:
- `skill(name="proofing")` — shared package API, handler integration patterns, migration order
- `skill(name="proofing-visual-parity")` — visual status display conventions per entity

## Panel Audit Template

For each admin proofing page/panel, fill out this template:

### Panel Identification

- **Page URL**: `/admin/proofing/{batchID}/{panel-name}`
- **Entity type(s)**: contest / polling_place / state_code / filing_paper / choice
- **View modes**: entities / associations / diff / detail / edit

### POST Handlers on This Page

| Handler | Action | Entity Type | Proofing Record Type | Current Status | Required Status |
|---|---|---|---|---|---|
| `PostXxxSave` | Save/edit | `contest` | `contest_meta` | `unresolved` | `reviewed` (resolve) |
| `PostXxxAdd` | Create | `contest` | `contest_meta` + `contest_state_code` + `choice_order` | single ad-hoc | loop over `ContestRequirements` |
| `PostXxxToggle` | Toggle flag | `filing_paper_page` | `filing_paper_page` | `unresolved` | depends on action |
| ... | | | | | |

For each handler, identify:
- Is it creating a record? → must use **Pattern A** (loop over requirements)
- Is it resolving a record? → must use **Pattern B** (single upsert with `reviewed`)
- Does the client server have a corresponding handler? → check its action specs

### Client Server Reference

Find the corresponding client handler and extract:
- What action specs does it use? (`ActionPageAccepted`, `ActionPageIgnored`, etc.)
- What proofing record types does it write?
- What status values does it set? (`reviewed`, `unresolved`)
- Does it set `Source`? (`accepted`, `ignored`)

### Visual Audit Checklist

For each sub-component rendered on this page:

- [ ] **Per-item status display**: Does each row/item show its proofing status?
- [ ] **Visual parity**: Does it match the client's mapping? (green=reviewed, amber=unresolved, red=needs_revision, gray=ignored)
- [ ] **Group summary**: If there are grouped items, is there a count breakdown per status?
- [ ] **Tree/matrix entry**: Does the entity type have an `entityTypeLabel()` entry?
- [ ] **candidate_entry**: If the entity has sub-candidate entries, are they rendered?

### Admin-Only Features (no client equivalent)

These are things the admin server has that the client doesn't:
- Progress tree with aggregated status per election
- Matrix view (contest × state code / polling place × state code)
- Batch-level summary
- Entity creation (add contest, add polling place, add state code)
- Bulk promote (batch import creates all proofing records)
- Filing paper upload and mapping to candidates

For each admin-only feature:
- Does it create proofing records? → must use requirements loop
- Does it display proofing status? → must use `OverallStatus()`
- Does it resolve records? → single upsert per action

### Changes Required

After completing the audit, produce:

1. **Handler changes**: list each POST handler and the exact proofing change needed
2. **Visual changes**: list each templ component and what visual treatment needs to change
3. **Tree/display changes**: list any new `entityTypeLabel` entries or status aggregation logic
4. **SQL/queries changes**: list any new queries needed (bulk inserts, status joins)

## Example: Filing Paper Audit

### Panel: Filing Paper Upload List (left sidebar)
- **Entity type**: filing_paper
- **POST handlers**: ToggleDuplicate, SaveChoice, DeleteUpload

| Handler | Current | Required |
|---|---|---|
| ToggleDuplicate | `status:unresolved` via local query | Use shared `UpsertProofingRecord` with `status:unresolved` + `source:nil` |
| SaveChoice | `status:unresolved` via local query | Same — admin always writes `unresolved`, client resolves |
| DeleteUpload | `DeleteProofingRecordByEntity` local query | No shared delete query — keep local for now |

### Visual: FilingPaperUploadPageRow
- **Current**: status dot + text label ("Unresolved" / "Reviewed" / "Ignored" / "Active ticket")
- **Missing**: border-left coloring per status, opacity for ignored pages, group summary counts

### Admin-only: Upload button, candidate mapping in edit panel
- These don't exist in the client server — admin uploads PDFs and maps candidates manually
- No proofing changes needed for the upload itself (PDF processor callback will create records in the future)

## Step-by-Step Per-Panel Workflow

1. Load both skills: `skill(name="proofing")` + `skill(name="proofing-visual-parity")`
2. Identify the entity type and handler files for the panel
3. Fill out the audit template above
4. Identify client server reference handler(s) and extract action specs
5. Determine which pattern applies per handler (A=create loop, B=resolve upsert, C=OverallStatus)
6. List all changes: handler code, templ visual, tree/display, SQL
7. Execute changes in order: SQL → imports → handler → templ → tree
8. Verify: create entity → check tree → complete action → check tree
9. Run `go build ./...` on affected server
```
