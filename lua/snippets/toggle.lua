local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("toggleprimary", {
    t("@components.PrimaryToggle(&structs.Checkbox{})"),
  }),

  s("toggleaccent", {
    t("@components.AccentToggle(&structs.Checkbox{})"),
  }),

  s("toggleattention", {
    t("@components.AttentionToggle(&structs.Checkbox{})"),
  }),

  s("toggleunique", {
    t("@components.UniqueToggle(&structs.Checkbox{})"),
  }),

  s("toggletertiary", {
    t("@components.TertiaryToggle(&structs.Checkbox{})"),
  }),

}
