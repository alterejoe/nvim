local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("form", {
    t("@components.Form(&structs.Form{})"),
  }),

}
