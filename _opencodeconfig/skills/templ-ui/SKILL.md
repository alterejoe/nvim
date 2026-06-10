---
name: templ-ui
description: "Templ component conventions for building UI pages. Covers props struct patterns, page vs partial rendering, flex chain requirements, autofocus placement, and the scroll chain. Load when writing templ files, building new pages, or debugging layout issues."
---

# Templ UI Conventions

## Props Structs

Every templ component that receives data uses a props struct:

```go
type ListPageProps struct {
    GroupID string
    Rows   []db.SelectXxxRow
    Search string
}

templ ListPage(props *ListPageProps) {
    // ...
}
```

Props are always passed as pointers. Define them in the same file as the component.

## Page vs Partial Rendering

**Full page** (GET requests loading a page):
```go
a.RenderPage(w, r, pkg.ListPage(&props))
```

**Partial** (HTMX responses, row updates):
```go
pkg.XxxRow(&props, &row).Render(r.Context(), w)
```

## The Flex Chain — Most Common Layout Bug

Every ancestor of a scrollable list needs `min-h-0` and `flex-1`:

```templ
<div class="flex flex-col flex-1 min-h-0">       // page wrapper
    <div class="flex flex-col flex-1 min-h-0">   // content area
        <div class="flex flex-col flex-1 min-h-0 overflow-y-auto">  // scrollable list
            for _, row := range props.Rows {
                @RowComponent(&row)
            }
        </div>
    </div>
</div>
```

If any ancestor in the chain is missing `min-h-0`, the list won't scroll — it will push the page height instead. This is the single most common layout bug and it's always the same fix.

## Autofocus Placement

`data-autofocus` goes on the outer panel div, NOT on the search input:

```templ
// CORRECT
<div data-keymap-panel="1" data-autofocus class="flex flex-col flex-1 min-h-0">
    <input data-keymap-action="/" placeholder="Search..." />
    // list...
</div>

// WRONG — search input gets autofocus
<div data-keymap-panel="1" class="flex flex-col flex-1 min-h-0">
    <input data-keymap-action="/" data-autofocus placeholder="Search..." />
```

The keymap system needs the panel focused, not the input. The input activates when you press `/`.

## Items End Alignment

When a labeled input sits next to a button, use `items-end` on the row:

```templ
<div class="flex flex-row gap-2 items-end">
    @gencomponents.InputDefaultLabeled("Label", &structs.Input{...})
    @gencomponents.AttentionButton(&structs.Button{...})
</div>
```

`items-end` aligns the button to the bottom of the row, flush with the input field, regardless of label height. `items-center` would center the button against the label+input stack.

## OOB Fragments

Out-of-band fragments for SSE/HTMX live in a separate `sse.templ` file, never in the page templ:

```templ
// sse.templ — used by handlers only, never rendered on page
templ MyRowOOB(groupID string, data RowData) {
    <div hx-swap-oob={ "beforeend:#group-rows-" + groupID }>
        @MyRow(data)
    </div>
}
```

Wrap `<details>`, `<tr>`, `<table>`, `<li>` in `<div hx-swap-oob="...">` — browsers strip semantic elements as top-level OOB fragments.
