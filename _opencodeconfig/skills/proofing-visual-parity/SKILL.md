---
name: proofing-visual-parity
description: "Visual proofing status display conventions shared between client and admin servers. Maps status values to colors, borders, labels, and opacity. Use when building or auditing admin detail/edit panels to ensure each entity's sub-components show their proofing state the same way the client server does."
---

# Proofing Visual Parity

## Problem

The client server has a defined visual language for displaying proofing status on entity sub-components (rows, items, detail panels). The admin server shows the same entities (filing paper pages, contest choices, polling places, state codes) but often lacks the same visual cues — a page row may show a generic status dot instead of the `reviewed=green` / `ignored=opacity` / `unresolved=amber` / `needs_revision=red` treatment the client gives it.

This causes confusion: an admin operator can't tell at a glance whether a filing paper was accepted or ignored without clicking into the detail.

## Visual Status Mapping (Client Server Reference)

Every entity sub-component that has a proofing status should display it using this mapping:

| Status | Condition | Visual Treatment | Label |
|---|---|---|---|
| `reviewed` | `!Duplicate && Status == "reviewed"` | Green left border (`border-l-green-500`), normal opacity | "Accepted" / "Reviewed" |
| `ignored` | `Duplicate && Status == "reviewed"` | Reduced opacity (`opacity-30..40`), gray left border (`border-l-gray-300`) | "Ignored" |
| `unresolved` | `!Duplicate && (Status == "" \|\| Status == "unresolved")` | Amber left border (`border-l-amber-400`) | "Unresolved" |
| `needs_revision` | `Status == "needs_revision"` | Red left border (`border-l-red-500`), red background (`bg-red-50`) | "Active ticket" |
| `pending` | no pages processed yet | Gray pill | "Pending" |

Group-level summary (upload group header) should show counts: `N accepted` (green), `N ignored` (amber), `N unresolved` (slate).

## Admin Server Audit Procedure

For each admin entity detail panel or page row:

1. **Identify the entity's sub-component** — what individual item is being displayed? (filing paper page, choice/contest row, polling place item, state code row, etc.)

2. **Does it have a `ProofingStatus` field?** If not, add it from the SQL query or data assembly.

3. **Compare its visual treatment against the mapping table above.** Does the sub-component use colored borders, opacity, and labels matching the status? Or just a generic status dot?

4. **Does the group-level view show aggregated counts?** Upload groups should show accepted/ignored/unresolved counts in the header.

5. **Is the status meaningful for this entity?** Admin-created entities stay `unresolved` until the client resolves them. The visual must reflect this — amber is correct, not an error.

## Visual Treatment Patterns

### Per-Item Row (from client ProcessedFilingPaperPageRow)

```html
<div class="flex flex-row items-center gap-4 px-4 py-3 border-t border-slate-100"
     data-page-row>
  <!-- Status-conditional classes -->
  <div class="{? border-l-4 }">
    <!-- green for reviewed, amber for unresolved, red for needs_revision, gray+opacity for ignored -->
  </div>
  <span class="text-xs font-medium">
    <!-- "Accepted filing paper" / "Unresolved" / "Active ticket" / "Ignored" -->
  </span>
</div>
```

### Group Summary (from client GroupPageSummary)

```html
<div class="flex flex-row gap-1 ml-2 text-xs">
  <span class="text-green-600 font-medium">N accepted</span>
  <span class="text-amber-600 font-medium">N ignored</span>
  <span class="text-slate-500">N unresolved</span>
</div>
```

### Status Dot (admin server's existing pattern — minimal but acceptable for tree nodes)

```go
func proofingStatusDot(status string) templ.Component {
    // green dot for reviewed, amber for unresolved, red for needs_revision, gray for ignored
}
```

For tree nodes and matrix cells, the dot is sufficient. For detail panel rows and page listings, use the full border+label treatment.

## Common Gaps Found in Admin Server

- `FilingPaperUploadPageRow`: uses `proofingStatusDot` + text label but no border-left coloring, no opacity for ignored pages
- Filing paper group headers: show page counts but no accepted/ignored/unresolved breakdown
- Contest choice rows: no proofing status display at all in choice detail view
- Polling place items in tree: status dot only, no detail-level per-child status
- `candidate_entry`: not yet rendered anywhere in admin tree or detail panels
- No `entityTypeLabel` entry for `"filing_paper_page"` or `"candidate_entry"`

## Checklist for Any Panel

- [ ] Each sub-component has a `ProofingStatus` field
- [ ] Visual treatment matches the mapping table (border, opacity, label)
- [ ] Group-level summaries show counts per status
- [ ] `entityTypeLabel()` covers this entity type if it appears in the tree
- [ ] Status values come from the database — no auto-derivation in the rendering path
```

---

## New Convention: `admin-panel-audit/SKILL.md`

Convention established: A structured per-panel evaluation framework for updating each admin page to use the shared proofing package and match the client server's patterns.

