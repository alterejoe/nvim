local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("disclosurechevron", {
    t("@components.DisclosureChevronDisclosureChevron(&structs.Button{})"),
  }),

  s("smalldisclosurechevron", {
    t("@components.SmallDisclosureChevronDisclosureChevron(&structs.Button{})"),
  }),

}
