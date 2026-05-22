local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("recursivestepbardefault", {
    t("@components.DefaultRecursiveStepBar(&structs.StepNavBar{})"),
  }),

}
