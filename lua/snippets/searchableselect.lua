local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("searchableselect", {
    t("@components.DefaultSearchableSelect(&structs.Select{})"),
  }),

}
