---
name: keymap-panels
description: "Keyboard navigation system for list/detail pages using data-keymap-* attributes. Covers panel numbering, action keys, radio toggle pattern, search scoping, and the edit form panel pattern. Load when building pages with keyboard navigation, debugging keymap issues, or adding interactive lists."
---

# Keymap Panels

## Panel Numbering

Each navigable section gets a `data-keymap-panel="N"` attribute. Navigation between panels uses `h`/`l`.

Standard layout:
- Panel 4: outer wrapper containing panel 1 + list (so `/` search scopes correctly)
- Panel 1: search input area
- Panel 2: detail/preview pane
- Panel 3: edit form (when opened)

The panel 4 wrapping panel 1 pattern is critical — without it, `/` (search) doesn't scope to the correct panel and the search input captures keystrokes meant for navigation.

## Action Keys

| Key | Action | Attribute |
|-----|--------|-----------|
| `/` | Focus search input | `data-keymap-action="/"` |
| `a` | Add new item | `data-keymap-action="a"` |
| `p` | Radio toggle | `data-keymap-action="p"` |
| `enter` | Submit/confirm | via `data-keymap-item` |
| `j`/`k` | Navigate list items | automatic on `data-keymap-item` |
| `h`/`l` | Switch panels | automatic |

## Search Scoping

Search input must be inside the panel it scopes to:

```templ
<div data-keymap-panel="4" class="flex flex-col flex-1 min-h-0">
    <div data-keymap-panel="1">
        <input data-keymap-action="/" placeholder="Search..." />
    </div>
    <div class="flex flex-col flex-1 min-h-0 overflow-y-auto">
        // list items with data-keymap-item
    </div>
</div>
```

## Radio Toggle Pattern

For boolean toggles (active/inactive, controlled/uncontrolled):

```templ
if props.Row.IsActive {
    @gencomponents.SimpleRadioButton(&structs.SimpleRadioButton{
        Common: structs.Common{Value: "Active"},
        Checked: true,
    })
    @gencomponents.SimpleRadioButton(&structs.SimpleRadioButton{
        Common: structs.Common{
            Value: "Inactive",
            Keymap: structs.Keymap{Action: "p"},  // only inactive gets p
        },
        Hx: structs.Hx{
            Method: structs.POST,
            URL:    "/admin/items/" + id + "/toggle?active=false",
            Target: "#row-" + id,
            Swap:   "outerHTML",
        },
    })
} else {
    @gencomponents.SimpleRadioButton(&structs.SimpleRadioButton{
        Common: structs.Common{
            Value: "Active",
            Keymap: structs.Keymap{Action: "p"},  // only inactive gets p
        },
        Hx: structs.Hx{
            Method: structs.POST,
            URL:    "/admin/items/" + id + "/toggle?active=true",
            Target: "#row-" + id,
            Swap:   "outerHTML",
        },
    })
    @gencomponents.SimpleRadioButton(&structs.SimpleRadioButton{
        Common: structs.Common{Value: "Inactive"},
        Checked: true,
    })
}
```

Rules:
- Only the INACTIVE radio gets `data-keymap-action="p"` — pressing `p` always toggles
- Use inline `if` blocks, not ternary — templ doesn't have ternary
- Swap target is the row with `outerHTML` so the action flips on re-render
- After swap, the active/inactive states reverse, so `p` now points to the other radio

## Edit Form Panel

```templ
<div id="edit-pane-content" class="flex flex-col flex-1 min-h-0"
     data-keymap-panel="3" data-keymap-scoped data-autofocus>
    // form content
    <div data-keymap-item data-keymap-item-inline>
        @gencomponents.PrimaryButton(&structs.Button{Type: "submit", ...})
    </div>
</div>
```

- `data-keymap-scoped` prevents action keys from leaking to the list while inside the form
- `data-autofocus` focuses the first item in the form's list on load
- Submit button wrapped in `data-keymap-item data-keymap-item-inline` so `j`/`k` can reach it and `enter` submits

## Sub-Panel Navigation

When a form has multiple tabs:

```templ
<div data-keymap-panel="4" data-keymap-panel-group="edit-contests"
     data-keymap-scoped data-autofocus class="flex flex-col flex-1 min-h-0">
```

Use `K`/`J` (capital) for tab switching within the edit form — `h`/`l` switches between major panels.

## Page Checklist

- [ ] Outer list panel: `data-keymap-panel="N"` + `flex flex-col flex-1 min-h-0`
- [ ] `data-autofocus` on outer panel div, NOT search input
- [ ] Search: `data-keymap-action="/"` inside outer panel
- [ ] Add button: `data-keymap-action="a"`
- [ ] Submit: `data-keymap-item data-keymap-item-inline`
- [ ] Edit form: `data-keymap-panel="3"` + `data-keymap-scoped` + `data-autofocus`
- [ ] Full flex chain on all ancestors of scrollable list (`min-h-0` + `flex-1`)
- [ ] Radio pairs: inline `if`, only inactive gets `p`, swap `outerHTML` on row
- [ ] No panel number collisions — grep for `data-keymap-panel` across related templ files
