local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node

return {

  s("stepbardefault", {
    t("@components.DefaultStepBar(&structs.StepBar{})"),
  }),

}
