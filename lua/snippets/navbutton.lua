local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("navprimary", {
    t("@components.PrimaryNavButton(&structs.Button{})"),
  }),

  s("navdefault", {
    t("@components.DefaultNavButton(&structs.Button{})"),
  }),

}
