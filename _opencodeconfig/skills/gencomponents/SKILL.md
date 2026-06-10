---
name: gencomponents
description: "Generated UI component system for templ. Covers when to use gencomponents vs raw HTML, struct composition (Common, Hx, FormBehavior, Keymap, Close), component naming, available variants, and conversion rules. Load when discussing UI components, converting HTML to components, or choosing between raw HTML and gencomponents."
---

# Gencomponents

A code generator that produces templ component functions from YAML config + Go templates. Components handle interactivity; raw HTML handles layout.

## The Conversion Rule

Only convert elements with interactivity:
- HTMX attributes (hx-get, hx-post, etc.)
- Form behavior (data-constraint, data-dirty-watch)
- Keymap attributes (data-keymap-action, etc.)
- Close triggers

Leave as raw HTML:
- Layout divs, flex containers, spacers
- Static labels, headings
- Hidden inputs
- `data-resize-*` elements
- `data-keymap-panel` wrapper divs

## Struct Composition

Every component accepts a struct with these embedded fields:

**Common:** ID, Name, Class, Value, TabIndex, Disabled, Autofocus, Autocomplete, Keymap, Close, Extras
**Hx:** Method (structs.GET/POST/PUT/DELETE), URL, Target, Swap, Trigger, Include, Indicator, Confirm, PushURL, Sync, OnAfterRequest, OnBeforeRequest, OnAfterSettle
**FormBehavior:** Required, DirtyWatch, Constraints []string, ConstraintForm
**Keymap:** Action, Label, Panel, Scoped, List, ListWrap, Item, ItemInline
**Close:** Trigger, On

Use `Extras` (map[string]string) for any `data-*` attributes not modeled in the struct.

## Component Naming

Pattern: `{Variant}{Component}` — e.g. `PrimaryButton`, `DefaultInput`, `AttentionButton`

**Not** `ButtonPrimary` or `InputDefault`. The variant comes first.

Exception: `Select` variants are `Select{Variant}` — e.g. `SelectDefault`, `SelectPrimary`.

## Available Components

- **Button** (9 variants): Primary, Secondary, Tertiary, Quaternary, Accent, Unique, Attention, Transparent, Ghost, Default
- **Input** (7 variants), **Textarea** (8), **Checkbox** (8), **RadioButton** (6), **SimpleRadioButton** (8), **Toggle** (5)
- **Select** (7 variants): SelectDefault, SelectPrimary, etc.
- **Link**, **LinkButton**, **Notice** (variant+size combos), **Chevron**
- **Form**, **FormError**, **FormSubmitButton**
- **LabeledInput**, **LabeledCheckbox**
- **Div**, **Window**, **Icons**

## Gotchas

- Select has NO Options field — use a children block with `<option>` tags inside
- Always set `Type: "button"` or `Type: "submit"` on buttons — omitting causes unexpected form submission
- Use `structs.GET`, `structs.POST`, etc. — not raw strings "GET", "POST"
- `DefaultInput` not `InputDefault` — the naming bit people repeatedly
- `Extras` for any `data-*` not in the struct — don't try to add fields to the struct

## Example

```go
@gencomponents.AttentionButton(&structs.Button{
    Common: structs.Common{
        ID:    "add-btn",
        Name:  "add",
        Value: "Add",
    },
    Hx: structs.Hx{
        Method:    structs.POST,
        URL:       "/admin/items/add",
        Target:    "#item-list",
        Swap:      "beforeend",
        Indicator: "#global-loader",
        Include:   "#add-name",
    },
    Type:     "submit",
    Disabled: true,
})
```

## Deprecated — Do Not Use

- `portal-shared/components` — old component library, replaced by gencomponents
- `TableData` param on props structs — repurposed, legacy usage
