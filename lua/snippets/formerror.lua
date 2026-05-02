local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("formerrordefault", {
    t("@components.DefaultFormError(&structs.{})"),
  }),

  s("formerrorlarge", {
    t("@components.LargeFormError(&structs.{})"),
  }),

}
